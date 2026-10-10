import CoreGraphics
import Foundation
import PladderCore

/// Watches the push-to-talk chords with a session-wide CGEvent tap.
///
/// A tap rather than `NSEvent` monitors because the chord may contain a regular
/// key: when the user picks Control+Space, the Space must not also land in the
/// text field they are dictating into, and only an active tap can drop events.
/// The tap sees every keyboard event in the login session, our own windows
/// included, so one tap replaces the old global + local monitor pair.
///
/// The tap lives on its own thread. An active tap hands every keystroke in the
/// system back before any other app sees it, and macOS disables a tap that takes
/// longer than about a second, so keyboard latency must never depend on our
/// main thread being free (menu tracking, model loading, ...). The callback
/// only takes a lock and yields to the stream.
///
/// Creating a keyboard tap requires Accessibility trust. `AppModel` keeps the
/// Carbon monitor in charge until the grant arrives and only then swaps this
/// one in, so a refused `CGEvent.tapCreate` is rare here, a grant revoked
/// between the poll and the start say; it is retried every couple of seconds
/// as a backstop, since there is no notification to wait for.
///
/// Several chords share the tap through `HotkeyChordSet`, which also decides
/// when Escape is the cancel key. Under Secure Event Input the tap sees no
/// key-downs at all, so Escape cannot cancel on the tap then; a modifier-only
/// chord keeps the tap in that state (see `HotkeySource`), and its recording
/// ends by letting go, the next press, or the cap.
///
/// Which keys are down is `HotkeyChordSet`'s business; this class only
/// translates events and owns the tap. The session bookkeeping, start, stop
/// and a stale install, is `HotkeyMonitorLifecycle`'s. It is
/// `@unchecked Sendable`: all mutable state lives behind the lifecycle's
/// lock, and the tap is created and torn down on the tap thread, whose run
/// loop it is attached to. The tap holds the monitor retained, so the monitor
/// outlives every callback, and lives until `stop` or the end of its stream
/// takes the tap down.
public final class GlobalHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct TapState: Sendable {
        var chords: HotkeyChordSet
        var modifiers = ModifierKeyState()
    }

    private let thread: RunLoopThread
    private let lifecycle: HotkeyMonitorLifecycle<TapHandle, TapState>

    /// How long to wait before trying to create the tap again when
    /// Accessibility has not been granted.
    private let retryInterval: TimeInterval = 2

    public init() {
        let thread = RunLoopThread(name: "Pladder.HotkeyTap", qualityOfService: .userInteractive)
        self.thread = thread
        lifecycle = HotkeyMonitorLifecycle(tearDown: { tap in thread.perform { tap.tearDown() } })
        thread.start()
    }

    deinit {
        stop()
        thread.finish()
    }

    // MARK: HotkeyMonitor

    public func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        // Starting twice replaces the previous session rather than stacking taps.
        let (stream, generation) = lifecycle.start { _ in
            TapState(chords: HotkeyChordSet(chords: chords, submitKey: submitKey))
        }
        thread.perform { [weak self] in
            self?.installTap(generation: generation)
        }
        return stream
    }

    public func stop() {
        lifecycle.stop()
    }

    /// A flag flip under the lock, nothing else: the tap reads it on the next
    /// key event.
    public func setCancelKeyEnabled(_ enabled: Bool) {
        lifecycle.withSession { $0.state.chords.cancelKeyEnabled = enabled }
    }

    // MARK: Tap

    /// Tap thread only.
    private func installTap(generation: UInt64) {
        guard lifecycle.needsResource(generation) else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Retained for as long as the tap can call back into it: released by
        // `TapHandle.tearDown` once the port is invalidated, or below when no
        // tap came of it.
        let monitor = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: monitor.toOpaque()
        ) else {
            // Not trusted for Accessibility. Poll: there is no notification.
            monitor.release()
            retryInstall(generation: generation)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            monitor.release()
            retryInstall(generation: generation)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        let tap = TapHandle(port: port, source: source, monitor: monitor)
        // Superseded while it was being made: down at once, on this thread,
        // before the run loop can hand it an event.
        if !lifecycle.adopt(tap, for: generation) { tap.tearDown() }
    }

    private func retryInstall(generation: UInt64) {
        DispatchQueue.global().asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            self?.thread.perform { [weak self] in
                self?.installTap(generation: generation)
            }
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: Event handling

    /// Returns true when the event must be dropped.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return false
        }

        // Our own synthetic Cmd+V (`PasteboardOutput`) passes through this tap
        // too. Its flags carry no device bits, so keep it out of the modifier
        // bookkeeping entirely.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else {
            return false
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        // One read per event, on the tap thread: the trackers time the
        // interruption window from it.
        let now = ContinuousClock.now

        // The mask asks for nothing else; the disabled notices went above.
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return false }
        let isRepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let step = lifecycle.withSession { session in
            let outcome: HotkeyChordSet.Outcome
            if type == .flagsChanged {
                let modifiers = session.state.modifiers.update(changedKey: keyCode, flags: flags)
                outcome = session.state.chords.flagsChanged(modifiers: modifiers, at: now)
            } else {
                let modifiers = session.state.modifiers.held(flags: flags)
                outcome = type == .keyDown
                    ? session.state.chords.keyDown(keyCode, isRepeat: isRepeat, modifiers: modifiers, at: now)
                    : session.state.chords.keyUp(keyCode, modifiers: modifiers, at: now)
            }
            return (outcome: outcome, continuation: session.continuation)
        }
        guard let (outcome, continuation) = step else { return false }

        for var event in outcome.events {
            event.instant = now
            continuation.yield(event)
        }
        return outcome.swallow
    }

    /// macOS disables a tap whose callback is too slow or when the user cancels
    /// with a keyboard interrupt. Turn it back on and start from a clean slate,
    /// since events were missed while it was off.
    private func reenable() {
        let reset = lifecycle.withSession { session in
            session.state.modifiers = ModifierKeyState()
            return (tap: session.resource, events: session.state.chords.reset(), continuation: session.continuation)
        }
        guard let reset else { return }
        if let tap = reset.tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
        let now = ContinuousClock.now
        for var event in reset.events {
            event.instant = now
            reset.continuation.yield(event)
        }
    }

    // MARK: Helpers

    /// The tap, its run loop source and the retained monitor its callback
    /// reads. Neither Core Foundation type is `Sendable`; they are only ever
    /// touched on the tap thread, so boxing them to hop there is safe.
    private struct TapHandle: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource
        let monitor: Unmanaged<GlobalHotkeyMonitor>

        /// Tap thread only, and exactly once per tap: by the lifecycle for an
        /// adopted one, by `installTap` for one it refused.
        func tearDown() {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(port)
            // Last: the callback runs on this thread, and none can follow an
            // invalidated port.
            monitor.release()
        }
    }
}
