import CoreGraphics
import Foundation
import PladderCore

// An active tap, because only it can drop the chord's Space. Its own thread: every
// keystroke waits on it, and macOS disables a tap that takes about a second, so it
// never waits for our main thread. `@unchecked`: state is behind the lifecycle's lock.
public final class GlobalHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct TapState: Sendable {
        var chords: HotkeyChordSet
        var modifiers = ModifierKeyState()
    }

    private let thread: RunLoopThread
    private let lifecycle: HotkeyMonitorLifecycle<TapHandle, TapState>
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

    // A flag flip under the lock; the tap reads it on the next key event.
    public func setCancelKeyEnabled(_ enabled: Bool) {
        lifecycle.withSession { $0.state.chords.cancelKeyEnabled = enabled }
    }

    // MARK: Tap

    // Tap thread only.
    private func installTap(generation: UInt64) {
        guard lifecycle.needsResource(generation) else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Retained while the tap can call back into it: released by `TapHandle.tearDown`,
        // or below when no tap came of it.
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
        // Superseded while it was being made: down at once, before the run loop hands it
        // an event.
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

    // True when the event must be dropped.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return false
        }

        // Our own synthetic Cmd+V passes through this tap too; its flags carry no device
        // bits, so it stays out of the modifier bookkeeping.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else {
            return false
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        // The trackers time the interruption window from this.
        let now = ContinuousClock.now

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

    // macOS disables a tap whose callback is too slow, or on a keyboard interrupt.
    // Events were missed meanwhile, so start from a clean slate.
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

    // Neither CF type is `Sendable`; both are touched on the tap thread only.
    private struct TapHandle: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource
        let monitor: Unmanaged<GlobalHotkeyMonitor>

        // Tap thread only, once per tap: by the lifecycle for an adopted one, by
        // `installTap` for one it refused.
        func tearDown() {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(port)
            // Last: the callback runs on this thread, and none can follow an invalidated port.
            monitor.release()
        }
    }
}
