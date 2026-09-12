import CoreGraphics
import Foundation
import PladderCore

/// Watches the push-to-talk chord with a session-wide CGEvent tap.
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
/// Creating a keyboard tap requires Accessibility trust; until it is granted
/// `CGEvent.tapCreate` returns nil and we simply try again every couple of
/// seconds, so the hotkey comes alive the moment the user ticks the box.
///
/// Which keys are down is `HotkeyChordTracker`'s business; this class only
/// translates events and owns the tap. It is `@unchecked Sendable`: all mutable
/// state lives behind `lock`, and the tap is created and torn down on the tap
/// thread, whose run loop it is attached to.
public final class GlobalHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
        var tracker: HotkeyChordTracker?
        var modifiers = ModifierKeyState()
        var tap: TapHandle?
        /// Bumped by every `start`/`stop` so an install that was scheduled onto
        /// the tap thread and then superseded quietly does nothing.
        var generation: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let thread = TapThread()

    /// How long to wait before trying to create the tap again when Accessibility
    /// has not been granted yet.
    public var retryInterval: TimeInterval = 2

    public init() {
        thread.start()
    }

    deinit {
        stop()
        thread.finish()
    }

    // MARK: HotkeyMonitor

    public func start(hotkey: Hotkey, submitKey: Hotkey) -> AsyncStream<HotkeyEvent> {
        // Starting twice replaces the previous session rather than stacking taps.
        stop()

        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(
            bufferingPolicy: .unbounded)

        let generation: UInt64 = lock.withLock {
            state.generation &+= 1
            state.continuation = continuation
            state.tracker = HotkeyChordTracker(hotkey: hotkey, submitKey: submitKey)
            state.modifiers = ModifierKeyState()
            return state.generation
        }

        // If the consumer drops the stream we must still take the tap down.
        continuation.onTermination = { [weak self] _ in
            self?.removeTap(generation: generation)
        }

        thread.perform { [weak self] in
            self?.installTap(generation: generation)
        }

        return stream
    }

    public func stop() {
        let (continuation, tap) = lock.withLock {
            state.generation &+= 1
            let result = (state.continuation, state.tap)
            state.continuation = nil
            state.tracker = nil
            state.tap = nil
            return result
        }
        // finish() may run onTermination synchronously; the lock is released and
        // the tap is already detached from `state`, so that is a no-op.
        continuation?.finish()
        removeTap(tap)
    }

    // MARK: Tap

    /// Tap thread only.
    private func installTap(generation: UInt64) {
        guard lock.withLock({ state.generation == generation && state.tap == nil }) else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            // Not trusted for Accessibility yet. Poll: there is no notification.
            DispatchQueue.global().asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                self?.thread.perform { [weak self] in
                    self?.installTap(generation: generation)
                }
            }
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        let tap = TapHandle(port: port, source: source)

        let stale: Bool = lock.withLock {
            guard state.generation == generation else { return true }
            state.tap = tap
            return false
        }
        if stale { tap.tearDown() }
    }

    private func removeTap(generation: UInt64) {
        let tap: TapHandle? = lock.withLock {
            guard state.generation == generation else { return nil }
            defer { state.tap = nil }
            return state.tap
        }
        removeTap(tap)
    }

    private func removeTap(_ tap: TapHandle?) {
        guard let tap else { return }
        thread.perform { tap.tearDown() }
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

        let (outcome, continuation) = lock.withLock {
            () -> (HotkeyChordTracker.Outcome, AsyncStream<HotkeyEvent>.Continuation?) in
            guard state.tracker != nil else { return (.init(), nil) }
            let outcome: HotkeyChordTracker.Outcome
            switch type {
            case .keyDown:
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                outcome = state.tracker!.keyDown(
                    keyCode, isRepeat: isRepeat, modifiers: state.modifiers.held(flags: flags))
            case .keyUp:
                outcome = state.tracker!.keyUp(keyCode, modifiers: state.modifiers.held(flags: flags))
            case .flagsChanged:
                let modifiers = state.modifiers.update(changedKey: keyCode, flags: flags)
                outcome = state.tracker!.flagsChanged(modifiers: modifiers)
            default:
                return (.init(), nil)
            }
            return (outcome, state.continuation)
        }

        if let event = outcome.event { continuation?.yield(event) }
        return outcome.swallow
    }

    /// macOS disables a tap whose callback is too slow or when the user cancels
    /// with a keyboard interrupt. Turn it back on and start from a clean slate,
    /// since events were missed while it was off.
    private func reenable() {
        let (tap, event, continuation) = lock.withLock {
            () -> (TapHandle?, HotkeyEvent?, AsyncStream<HotkeyEvent>.Continuation?) in
            let event = state.tracker?.reset()
            state.modifiers = ModifierKeyState()
            return (state.tap, event, state.continuation)
        }
        if let tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
        if let event { continuation?.yield(event) }
    }

    // MARK: Helpers

    /// The tap and its run loop source. Neither Core Foundation type is
    /// `Sendable`; they are only ever touched on the tap thread, so boxing them
    /// to hop there is safe.
    private struct TapHandle: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource

        /// Tap thread only.
        func tearDown() {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(port)
        }
    }

    /// A thread that does nothing but run a run loop for the tap. Work is
    /// handed to it as blocks, which is how the tap gets installed and removed
    /// on the same thread whose run loop it lives on.
    private final class TapThread: Thread, @unchecked Sendable {
        private let condition = NSCondition()
        private var loop: CFRunLoop?

        override init() {
            super.init()
            name = "Pladder.HotkeyTap"
            qualityOfService = .userInteractive
        }

        override func main() {
            condition.lock()
            loop = CFRunLoopGetCurrent()
            condition.broadcast()
            condition.unlock()
            // A run loop with nothing to watch returns straight away; the tap's
            // source only arrives later, so keep a port on it until told to stop.
            RunLoop.current.add(NSMachPort(), forMode: .common)
            while !isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }

        func perform(_ block: @escaping @Sendable () -> Void) {
            condition.lock()
            while loop == nil { condition.wait() }
            let loop = loop!
            condition.unlock()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(loop)
        }

        func finish() {
            cancel()
            perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
        }
    }
}
