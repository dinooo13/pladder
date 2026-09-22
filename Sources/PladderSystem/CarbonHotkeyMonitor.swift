import Carbon.HIToolbox
import Foundation
import PladderCore
import os

/// Watches the push-to-talk chords with Carbon's `RegisterEventHotKey`, which
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
/// Each chord is its own hot key; a chord that cannot be registered is
/// skipped on its own, the others still work.
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
        var continuation: AsyncStream<HotkeyMonitorEvent>.Continuation?
        var registration: Registration?
        /// The role behind each hot key ID of the current session.
        var roles: [UInt32: HotkeyRole] = [:]
        /// Carbon repeats `kEventHotKeyPressed` while the key is held on some
        /// configurations, and a release can arrive with nothing pressed
        /// after a `stop()`; this makes each role's events strictly
        /// alternating.
        var pressed: Set<HotkeyRole> = []
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

    public func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        // Starting twice replaces the previous session rather than stacking
        // registrations, the same rule `GlobalHotkeyMonitor` follows.
        stop()

        let (stream, continuation) = AsyncStream<HotkeyMonitorEvent>.makeStream(
            bufferingPolicy: .unbounded)

        let generation: UInt32 = lock.withLock {
            state.generation &+= 1
            state.continuation = continuation
            state.pressed = []
            state.roles = [:]
            return state.generation
        }

        var entries: [HotKeyEntry] = []
        for (role, chord) in chords.sorted(by: { $0.key < $1.key }) where !chord.isEmpty {
            guard chord.canBeRegisteredWithoutAccessibility,
                  let keyCode = chord.regularKeyCodes.first else {
                // Nothing to register for this role. The stream stays open so
                // the coordinator behaves exactly as it does before a tap
                // comes up; the settings window is where the user is told to
                // pick a chord with a regular key.
                let codes = chord.keyCodes.sorted().map(String.init).joined(separator: ", ")
                Self.log.error(
                    """
                    Without Accessibility the chord needs exactly one regular key and no Fn; \
                    the \(role.rawValue, privacy: .public) chord [\(codes, privacy: .public)] cannot be registered.
                    """
                )
                continue
            }
            entries.append(HotKeyEntry(
                role: role,
                id: Self.hotKeyID(generation: generation, role: role),
                keyCode: UInt32(keyCode),
                modifiers: chord.carbonModifierMask))
        }
        lock.withLock {
            guard state.generation == generation else { return }
            for entry in entries { state.roles[entry.id] = entry.role }
        }

        // If the consumer drops the stream the hot keys must still go away.
        continuation.onTermination = { [weak self] _ in
            self?.unregister(generation: generation)
        }

        guard !entries.isEmpty else { return stream }
        onMain { [weak self, entries] in
            self?.register(entries, generation: generation)
        }

        return stream
    }

    public func stop() {
        let (continuation, registration) = lock.withLock {
            () -> (AsyncStream<HotkeyMonitorEvent>.Continuation?, Registration?) in
            state.generation &+= 1
            let result = (state.continuation, state.registration)
            state.continuation = nil
            state.registration = nil
            state.roles = [:]
            state.pressed = []
            return result
        }
        // `finish()` may run `onTermination` synchronously; the lock is
        // released and the registration is already detached, so that is a
        // no-op.
        continuation?.finish()
        Self.tearDown(registration)
    }

    // MARK: Registration

    /// The session's hot keys and the one event handler that feeds them all.
    /// Neither Carbon type is `Sendable`; both are only ever created and
    /// destroyed on the main thread, so boxing them to hop there is safe.
    private struct Registration: @unchecked Sendable {
        var hotKeys: [EventHotKeyRef]
        var handler: EventHandlerRef?
    }

    /// One chord to register: which role it is, the ID its events carry, and
    /// Carbon's spelling of it.
    private struct HotKeyEntry: Sendable {
        var role: HotkeyRole
        var id: UInt32
        var keyCode: UInt32
        var modifiers: UInt32
    }

    /// The generation in the high bits and the role's index in the low three,
    /// so one session's hot keys are told apart and an old session's ignored.
    private static func hotKeyID(generation: UInt32, role: HotkeyRole) -> UInt32 {
        let index = UInt32(HotkeyRole.allCases.firstIndex(of: role) ?? 0)
        return (generation &<< 3) | index
    }

    /// Main thread only.
    private func register(_ entries: [HotKeyEntry], generation: UInt32) {
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

        var hotKeys: [EventHotKeyRef] = []
        for entry in entries {
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: entry.id)
            let registered = RegisterEventHotKey(
                entry.keyCode, entry.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            guard registered == noErr, let hotKey else {
                // This chord is lost; the others still work.
                let role = entry.role.rawValue
                if registered == OSStatus(eventHotKeyExistsErr) {
                    Self.log.error("The \(role, privacy: .public) key is already in use by another app")
                } else {
                    Self.log.error("Could not register the \(role, privacy: .public) key (\(registered, privacy: .public))")
                }
                continue
            }
            hotKeys.append(hotKey)
        }
        guard !hotKeys.isEmpty else {
            RemoveEventHandler(handler)
            return
        }

        let registration = Registration(hotKeys: hotKeys, handler: handler)
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
              !registration.hotKeys.isEmpty || registration.handler != nil else { return }
        onMainThread {
            for hotKey in registration.hotKeys { UnregisterEventHotKey(hotKey) }
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
        let now = ContinuousClock.now
        let (outcome, continuation) = lock.withLock {
            () -> (HotkeyMonitorEvent?, AsyncStream<HotkeyMonitorEvent>.Continuation?) in
            // An event for a hot key we have already replaced.
            guard id.id >> 3 == state.generation & (UInt32.max >> 3),
                  let role = state.roles[id.id] else { return (nil, nil) }
            switch Int(kind) {
            case kEventHotKeyPressed:
                guard state.pressed.insert(role).inserted else { return (nil, nil) }
                return (HotkeyMonitorEvent(role: role, event: .pressed, instant: now), state.continuation)
            case kEventHotKeyReleased:
                guard state.pressed.remove(role) != nil else { return (nil, nil) }
                // No send key here: posting the Return it asks for needs the
                // grant this monitor exists to do without.
                return (
                    HotkeyMonitorEvent(role: role, event: .released(submit: false), instant: now),
                    state.continuation)
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
