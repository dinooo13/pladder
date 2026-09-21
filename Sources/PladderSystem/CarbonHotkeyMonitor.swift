import Carbon.HIToolbox
import Foundation
import PladderCore
import os

/// Watches the push-to-talk chord with Carbon's `RegisterEventHotKey`, which
/// needs no permission at all.
///
/// This is the fallback for accounts that cannot grant Accessibility: a
/// standard (non-admin) user is asked for an administrator password when they
/// tick the Accessibility box, and Input Monitoring is gated the same way, so
/// the event tap in `GlobalHotkeyMonitor` never comes alive for them.
/// `RegisterEventHotKey` is the one system-wide hotkey API with no privacy
/// gate; the window server consumes the combination, so the front app never
/// sees it, which is what the tap's swallowing does when trusted.
///
/// What it cannot do, and why this is only the fallback:
/// - the chord needs exactly one regular key: a modifier-only chord such as
///   Right Command cannot be registered (`Hotkey`'s
///   `canBeRegisteredWithoutAccessibility` is the predicate),
/// - the modifier mask is side-agnostic, so Left and Right Shift are the same
///   chord here, and there is no bit for Fn,
/// - the send key is not supported: it would need a second observer of the
///   keyboard, and posting the Return it asks for needs Accessibility anyway.
///   `submitKey` is therefore ignored and every release says `submit: false`.
///
/// This stays a dumb registrar: an unregistrable chord is refused here, and it
/// is `AppModel` that hands the coordinator the default chord instead, since
/// the menu and the settings window have to name what is actually being
/// listened for. See `Hotkey.standInWithoutAccessibility`.
///
/// Carbon delivers its events on the main run loop, and registration is main
/// thread work, so everything hops there. Mutable state lives behind `lock`
/// because the protocol is `Sendable` and callers are not all on the main
/// actor.
public final class CarbonHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
        var registration: Registration?
        /// Carbon repeats `kEventHotKeyPressed` while the key is held on some
        /// configurations, and a release can arrive with nothing pressed
        /// after a `stop()`; this makes the stream strictly alternating.
        var isPressed = false
        /// Bumped by every `start`/`stop` so a registration that was scheduled
        /// onto the main thread and then superseded quietly undoes itself, and
        /// so events for an old hot key are ignored.
        var generation: UInt32 = 0
    }

    private let lock = NSLock()
    private var state = State()

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")

    /// 'PLDR' as a four-character code. Every hot key we register carries it,
    /// so the handler can tell our events from another client's.
    private static let signature: OSType = Array("PLDR".utf8)
        .reduce(OSType(0)) { ($0 << 8) | OSType($1) }

    public init() {}

    deinit {
        // `stop()` hands the registration to a static helper, so nothing
        // escapes self here.
        stop()
    }

    // MARK: HotkeyMonitor

    public func start(hotkey: Hotkey, submitKey: Hotkey) -> AsyncStream<HotkeyEvent> {
        // Starting twice replaces the previous session rather than stacking
        // registrations, the same rule `GlobalHotkeyMonitor` follows.
        stop()

        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(
            bufferingPolicy: .unbounded)

        let generation: UInt32 = lock.withLock {
            state.generation &+= 1
            state.continuation = continuation
            state.isPressed = false
            return state.generation
        }

        // If the consumer drops the stream the hot key must still go away.
        continuation.onTermination = { [weak self] _ in
            self?.unregister(generation: generation)
        }

        guard hotkey.canBeRegisteredWithoutAccessibility,
              let keyCode = hotkey.regularKeyCodes.first else {
            // Nothing to register. The stream stays open and silent so the
            // coordinator behaves exactly as it does before a tap comes up;
            // the settings window is where the user is told to pick a chord
            // with a regular key.
            let codes = hotkey.keyCodes.sorted().map(String.init).joined(separator: ", ")
            Self.log.error(
                """
                Without Accessibility the chord needs exactly one regular key and no Fn; \
                the chord [\(codes, privacy: .public)] cannot be registered.
                """
            )
            return stream
        }

        let modifiers = hotkey.carbonModifierMask
        onMain { [weak self] in
            self?.register(keyCode: UInt32(keyCode), modifiers: modifiers, generation: generation)
        }

        return stream
    }

    public func stop() {
        let (continuation, registration) = lock.withLock {
            () -> (AsyncStream<HotkeyEvent>.Continuation?, Registration?) in
            state.generation &+= 1
            let result = (state.continuation, state.registration)
            state.continuation = nil
            state.registration = nil
            state.isPressed = false
            return result
        }
        // `finish()` may run `onTermination` synchronously; the lock is
        // released and the registration is already detached, so that is a
        // no-op.
        continuation?.finish()
        Self.tearDown(registration)
    }

    // MARK: Registration

    /// The hot key and the event handler that feeds it. Neither Carbon type is
    /// `Sendable`; both are only ever created and destroyed on the main
    /// thread, so boxing them to hop there is safe.
    private struct Registration: @unchecked Sendable {
        var hotKey: EventHotKeyRef?
        var handler: EventHandlerRef?
    }

    /// Main thread only.
    private func register(keyCode: UInt32, modifiers: UInt32, generation: UInt32) {
        guard lock.withLock({ state.generation == generation && state.registration == nil })
        else { return }

        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), Self.eventHandler,
            specs.count, &specs, refcon, &handler)
        guard installed == noErr else {
            Self.log.error("Could not install the hot key handler (\(installed, privacy: .public))")
            return
        }

        var hotKey: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: generation)
        let registered = RegisterEventHotKey(
            keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr, hotKey != nil else {
            if registered == OSStatus(eventHotKeyExistsErr) {
                Self.log.error("The push-to-talk key is already in use by another app")
            } else {
                Self.log.error("Could not register the push-to-talk key (\(registered, privacy: .public))")
            }
            RemoveEventHandler(handler)
            return
        }

        let registration = Registration(hotKey: hotKey, handler: handler)
        let stale: Bool = lock.withLock {
            guard state.generation == generation else { return true }
            state.registration = registration
            return false
        }
        if stale { Self.tearDown(registration) }
    }

    private func unregister(generation: UInt32) {
        let registration: Registration? = lock.withLock {
            guard state.generation == generation else { return nil }
            defer { state.registration = nil }
            return state.registration
        }
        Self.tearDown(registration)
    }

    private static func tearDown(_ registration: Registration?) {
        guard let registration,
              registration.hotKey != nil || registration.handler != nil else { return }
        onMainThread {
            if let hotKey = registration.hotKey { UnregisterEventHotKey(hotKey) }
            if let handler = registration.handler { RemoveEventHandler(handler) }
        }
    }

    // MARK: Events

    private static let eventHandler: EventHandlerUPP = { _, event, refcon in
        guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
        let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(event)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let read = GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard read == noErr, id.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }

        let kind = GetEventKind(event)
        let (outcome, continuation) = lock.withLock {
            () -> (HotkeyEvent?, AsyncStream<HotkeyEvent>.Continuation?) in
            // An event for a hot key we have already replaced.
            guard id.id == state.generation else { return (nil, nil) }
            switch Int(kind) {
            case kEventHotKeyPressed:
                guard !state.isPressed else { return (nil, nil) }
                state.isPressed = true
                return (.pressed, state.continuation)
            case kEventHotKeyReleased:
                guard state.isPressed else { return (nil, nil) }
                state.isPressed = false
                // No send key here: posting the Return it asks for needs the
                // grant this monitor exists to do without.
                return (.released(submit: false), state.continuation)
            default:
                return (nil, nil)
            }
        }

        if let outcome { continuation?.yield(outcome) }
        return noErr
    }

    // MARK: Helpers

    private func onMain(_ block: @escaping @Sendable () -> Void) {
        Self.onMainThread(block)
    }

    private static func onMainThread(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
