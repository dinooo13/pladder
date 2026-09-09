import AppKit
import Foundation
import SpeakUpCore

/// Watches the push-to-talk key with `NSEvent` monitors.
///
/// Two monitors are installed on purpose:
/// - the *global* monitor sees events delivered to other applications, which is
///   the normal case while dictating into someone else's text field. It requires
///   Accessibility trust and never sees events aimed at us.
/// - the *local* monitor sees events delivered to our own windows, so the hotkey
///   still works while the settings window or the menu is frontmost. It gets no
///   events from other apps, hence both are needed and their results are
///   de-duplicated by the press/release state below.
///
/// The class is `@unchecked Sendable`: all mutable state lives behind `lock`, and
/// every `NSEvent` monitor add/remove is funnelled onto the main thread.
public final class GlobalHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
        var globalMonitor: MonitorToken?
        var localMonitor: MonitorToken?
        /// True between an emitted `.pressed` and its matching `.released`, so we
        /// never emit two `.pressed` in a row (global + local monitors can both
        /// see the same event, and modifiers can repeat).
        var isPressed = false
        /// Bumped by every `start`/`stop` so an install that was scheduled onto
        /// the main thread and then superseded quietly does nothing.
        var generation: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    // MARK: HotkeyMonitor

    public func start(hotkey: Hotkey) -> AsyncStream<HotkeyEvent> {
        // Starting twice replaces the previous session rather than stacking
        // monitors, which would double every event.
        stop()

        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(
            bufferingPolicy: .unbounded)

        let generation: UInt64 = lock.withLock {
            state.generation &+= 1
            state.continuation = continuation
            state.isPressed = false
            return state.generation
        }

        // If the consumer drops the stream we must still take the monitors down.
        continuation.onTermination = { [weak self] _ in
            self?.removeMonitors(generation: generation)
        }

        let mask: NSEvent.EventTypeMask =
            hotkey.kind == .modifier ? [.flagsChanged] : [.keyDown, .keyUp]

        onMain { [weak self] in
            guard let self else { return }
            // Bail out if another start/stop happened while we were hopping.
            guard self.lock.withLock({ self.state.generation == generation }) else { return }

            let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event, hotkey: hotkey, generation: generation)
            }
            let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event, hotkey: hotkey, generation: generation)
                // Pass the event through: the hotkey must not swallow typing in
                // our own windows.
                return event
            }

            let stale: Bool = self.lock.withLock {
                guard self.state.generation == generation else { return true }
                self.state.globalMonitor = global.map(MonitorToken.init(value:))
                self.state.localMonitor = local.map(MonitorToken.init(value:))
                return false
            }
            if stale {
                if let global { NSEvent.removeMonitor(global) }
                if let local { NSEvent.removeMonitor(local) }
            }
        }

        return stream
    }

    public func stop() {
        let (continuation, global, local) = lock.withLock {
            state.generation &+= 1
            let result = (state.continuation, state.globalMonitor, state.localMonitor)
            state.continuation = nil
            state.globalMonitor = nil
            state.localMonitor = nil
            state.isPressed = false
            return result
        }
        // finish() may run onTermination synchronously; the lock is released and
        // the monitors are already detached from `state`, so that is a no-op.
        continuation?.finish()
        removeMonitors(global: global, local: local)
    }

    // MARK: Event handling

    private func handle(_ event: NSEvent, hotkey: Hotkey, generation: UInt64) {
        guard lock.withLock({ state.generation == generation }) else { return }
        switch hotkey.kind {
        case .modifier: handleModifier(event, hotkey: hotkey)
        case .key: handleKey(event, hotkey: hotkey)
        }
    }

    private func handleModifier(_ event: NSEvent, hotkey: Hotkey) {
        guard event.type == .flagsChanged else { return }
        // `keyCode` is what distinguishes right Option from left Option; the
        // modifier flags themselves are side agnostic.
        guard event.keyCode == hotkey.keyCode,
              let flag = Self.modifierFlag(forKeyCode: hotkey.keyCode)
        else { return }

        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Caps Lock is a latched state rather than part of a chord, so it must
        // not disqualify the "held alone" test below.
        if flag != .capsLock { flags.subtract(.capsLock) }

        if flags.contains(flag) {
            // Only push-to-talk when the modifier is held *alone*. Otherwise
            // ordinary chords such as Option+Command+Space would start a
            // recording as a side effect.
            guard flags == flag else { return }
            emitPressed()
        } else {
            emitReleased()
        }
    }

    private func handleKey(_ event: NSEvent, hotkey: Hotkey) {
        switch event.type {
        case .keyDown:
            // Holding a key auto-repeats; only the first press starts recording.
            guard !event.isARepeat, event.keyCode == hotkey.keyCode else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.rawValue == hotkey.modifiers else { return }
            emitPressed()
        case .keyUp:
            // Modifiers are often released before the key, so ignore them here
            // and match on the key code only.
            guard event.keyCode == hotkey.keyCode else { return }
            emitReleased()
        default:
            return
        }
    }

    private func emitPressed() {
        let continuation: AsyncStream<HotkeyEvent>.Continuation? = lock.withLock {
            guard !state.isPressed, let continuation = state.continuation else { return nil }
            state.isPressed = true
            return continuation
        }
        continuation?.yield(.pressed)
    }

    private func emitReleased() {
        let continuation: AsyncStream<HotkeyEvent>.Continuation? = lock.withLock {
            guard state.isPressed, let continuation = state.continuation else { return nil }
            state.isPressed = false
            return continuation
        }
        continuation?.yield(.released)
    }

    // MARK: Monitors

    private func removeMonitors(generation: UInt64) {
        let (global, local) = lock.withLock { () -> (MonitorToken?, MonitorToken?) in
            guard state.generation == generation else { return (nil, nil) }
            let result = (state.globalMonitor, state.localMonitor)
            state.globalMonitor = nil
            state.localMonitor = nil
            return result
        }
        removeMonitors(global: global, local: local)
    }

    private func removeMonitors(global: MonitorToken?, local: MonitorToken?) {
        guard global != nil || local != nil else { return }
        onMain {
            if let global { NSEvent.removeMonitor(global.value) }
            if let local { NSEvent.removeMonitor(local.value) }
        }
    }

    /// The opaque object `NSEvent` hands back is typed `Any`, so it carries no
    /// `Sendable` conformance. It is inert data for us and is only ever passed
    /// back to AppKit on the main thread, so boxing it is safe.
    private struct MonitorToken: @unchecked Sendable {
        let value: Any
    }

    /// NSEvent monitors must be installed and removed on the main thread, and
    /// `start`/`stop` are usually already called from `@MainActor` code, so run
    /// inline when we are there and hop otherwise.
    private func onMain(_ body: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Virtual key codes for the modifier keys, mapped to the flag they set.
    /// Left and right variants share a flag, which is why the key code is the
    /// thing we match on.
    private static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x3A, 0x3D: return .option   // left, right Option
        case 0x37, 0x36: return .command  // left, right Command
        case 0x3B, 0x3E: return .control  // left, right Control
        case 0x38, 0x3C: return .shift    // left, right Shift
        case 0x3F: return .function       // Fn / Globe
        case 0x39: return .capsLock
        default: return nil
        }
    }
}
