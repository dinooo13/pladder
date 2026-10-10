import Carbon.HIToolbox
import Foundation
import PladderCore
import os

// The fallback without Accessibility: `RegisterEventHotKey` has no privacy gate, and
// the window server consumes the chord. Its limits: docs/ARCHITECTURE.md, "Hotkeys".
// `@unchecked Sendable`: mutable state is behind the lifecycle's lock.
public final class CarbonHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private struct SessionState: Sendable {
        var hotKeys: CarbonHotkeySession
        var cancelKey: CancelKey?
        // Remembered so an enable that lands before the session's registration is honoured.
        var cancelKeyWanted = false
    }

    private let lifecycle = HotkeyMonitorLifecycle<Registration, SessionState>(
        tearDown: { registration in CarbonHotkeyMonitor.onMainThread { registration.tearDown() } },
        ended: { state in
            guard let cancelKey = state.cancelKey else { return }
            CarbonHotkeyMonitor.onMainThread { UnregisterEventHotKey(cancelKey.hotKey) }
        })

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")

    // On every hot key we register, so the handler can tell ours from another client's.
    private static let signature: OSType = Array("PLDR".utf8)
        .reduce(OSType(0)) { ($0 << 8) | OSType($1) }

    public init() {}

    deinit {
        // Runs only once no handler holds the monitor.
        stop()
    }

    // MARK: HotkeyMonitor

    public func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        var registrable: [HotKeyEntry] = []
        for (role, chord) in chords.sorted(by: { $0.key < $1.key }) where !chord.isEmpty {
            guard chord.canBeRegisteredWithoutAccessibility,
                  let keyCode = chord.regularKeyCodes.first else {
                // The stream stays open, so the coordinator behaves as it does before a tap comes
                // up; the settings window tells the user to pick a chord with a regular key.
                let codes = chord.keyCodes.sorted().map(String.init).joined(separator: ", ")
                Self.log.error(
                    """
                    Without Accessibility the chord needs exactly one regular key and no Fn; \
                    the \(role.rawValue, privacy: .public) chord [\(codes, privacy: .public)] cannot be registered.
                    """
                )
                continue
            }
            registrable.append(HotKeyEntry(role: role, keyCode: UInt32(keyCode), modifiers: chord.carbonModifierMask))
        }

        let (stream, generation) = lifecycle.start { generation in
            SessionState(hotKeys: CarbonHotkeySession(generation: generation, roles: registrable.map(\.role)))
        }
        guard !registrable.isEmpty else { return stream }
        Self.onMainThread { [weak self, registrable] in
            self?.register(registrable, generation: generation)
        }
        return stream
    }

    public func stop() {
        lifecycle.stop()
    }

    // Never registers inline: this is called on the release path, and a Carbon call
    // there would wait on the window server.
    public func setCancelKeyEnabled(_ enabled: Bool) {
        let generation = lifecycle.withSession { session in
            session.state.cancelKeyWanted = enabled
            return session.generation
        }
        guard let generation else { return }
        DispatchQueue.main.async { [weak self] in
            self?.syncCancelKey(generation: generation)
        }
    }

    // MARK: Registration

    // Neither Carbon type is `Sendable`; both are created and destroyed on the main
    // thread only, so boxing them to hop there is safe.
    private struct Registration: @unchecked Sendable {
        let hotKeys: [EventHotKeyRef]
        let handler: EventHandlerRef
        let monitor: Unmanaged<CarbonHotkeyMonitor>

        // Main thread only, once per registration: by the lifecycle for an adopted one, by
        // `register` for one it refused.
        func tearDown() {
            for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
            RemoveEventHandler(handler)
            // Last: events arrive on this thread, and none can follow the handler's removal.
            monitor.release()
        }
    }

    // Created and destroyed on the main thread only.
    private struct CancelKey: @unchecked Sendable {
        var hotKey: EventHotKeyRef
    }

    private struct HotKeyEntry: Sendable {
        var role: HotkeyRole
        var keyCode: UInt32
        var modifiers: UInt32
    }

    // Main thread only.
    private func register(_ entries: [HotKeyEntry], generation: UInt64) {
        guard lifecycle.needsResource(generation) else { return }

        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Retained while the handler can call back into it: released by
        // `Registration.tearDown`, or below when no registration came of it.
        let monitor = Unmanaged.passRetained(self)
        var handler: EventHandlerRef?
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), Self.eventHandler,
            specs.count, &specs, monitor.toOpaque(), &handler)
        guard installed == noErr, let handler else {
            monitor.release()
            Self.log.error("Could not install the hot key handler (\(installed, privacy: .public))")
            return
        }

        var hotKeys: [EventHotKeyRef] = []
        for entry in entries {
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(
                signature: Self.signature, id: CarbonHotkeySession.hotKeyID(generation: generation, role: entry.role))
            let registered = RegisterEventHotKey(
                entry.keyCode, entry.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            guard registered == noErr, let hotKey else {
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
            monitor.release()
            return
        }

        let registration = Registration(hotKeys: hotKeys, handler: handler, monitor: monitor)
        guard lifecycle.adopt(registration, for: generation) else {
            registration.tearDown()
            return
        }
        // A recording that started before the handler was in place.
        syncCancelKey(generation: generation)
    }

    // Main thread only. Needs the session's handler, which exists once a chord registered.
    private func syncCancelKey(generation: UInt64) {
        let snapshot = lifecycle.withSession(generation) { session in
            // Taken under the lock, so a session ending meanwhile, whose `ended` unregisters it
            // too, cannot unregister it twice.
            let taken = session.state.cancelKeyWanted ? nil : session.state.cancelKey
            if taken != nil { session.state.cancelKey = nil }
            return (wanted: session.state.cancelKeyWanted, current: session.state.cancelKey, taken: taken,
                    registered: session.resource != nil, id: session.state.hotKeys.cancelKeyID)
        }
        guard let snapshot else { return }
        if let taken = snapshot.taken {
            UnregisterEventHotKey(taken.hotKey)
            return
        }
        guard snapshot.wanted, snapshot.current == nil, snapshot.registered else { return }
        var hotKey: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: snapshot.id)
        let registered = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr, let hotKey else {
            if registered == OSStatus(eventHotKeyExistsErr) {
                Self.log.error("Escape is registered by another app; it cannot cancel a recording")
            } else {
                Self.log.error("Could not register Escape (\(registered, privacy: .public))")
            }
            return
        }
        let kept = lifecycle.withSession(generation) { session -> Bool in
            guard session.state.cancelKeyWanted, session.state.cancelKey == nil else { return false }
            session.state.cancelKey = CancelKey(hotKey: hotKey)
            return true
        } ?? false
        if !kept { UnregisterEventHotKey(hotKey) }
    }

    // MARK: Events

    private static let eventHandler: EventHandlerUPP = { _, event, refcon in
        guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
        let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(event)
    }

    // Main thread only, as Carbon delivers it.
    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let read = GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard read == noErr, id.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }
        let kind = Int(GetEventKind(event))
        guard kind == kEventHotKeyPressed || kind == kEventHotKeyReleased else { return noErr }

        let now = ContinuousClock.now
        let step = lifecycle.withSession { session in
            let meaning = session.state.hotKeys.event(
                id: id.id, isPress: kind == kEventHotKeyPressed,
                cancelKeyRegistered: session.state.cancelKey != nil)
            return (meaning: meaning, continuation: session.continuation)
        }
        if let step, let meaning = step.meaning {
            step.continuation.yield(HotkeyMonitorEvent(meaning, instant: now))
        }
        return noErr
    }

    // MARK: Helpers

    private static func onMainThread(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
