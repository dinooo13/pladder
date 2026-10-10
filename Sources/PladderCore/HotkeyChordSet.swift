import Foundation

// See docs/ARCHITECTURE.md, "Hotkeys".
public struct HotkeyChordSet: Sendable, Equatable {
    public struct Outcome: Sendable, Equatable {
        public var events: [HotkeyMonitorEvent]
        public var swallow: Bool

        public init(events: [HotkeyMonitorEvent] = [], swallow: Bool = false) {
            self.events = events
            self.swallow = swallow
        }
    }

    // Parallel arrays sorted by role: a stable event order, and a synthesised `==`.
    private let roles: [HotkeyRole]
    private var trackers: [HotkeyChordTracker]
    public var cancelKeyEnabled = false
    private var isSwallowingCancelKey = false
    private static let cancelKey: UInt16 = 0x35 // kVK_Escape

    public init(
        chords: [HotkeyRole: Hotkey],
        submitKey: Hotkey = Hotkey(keyCodes: []),
        interruptionWindow: Duration = .seconds(1)
    ) {
        let active = chords.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        roles = active.map(\.key)
        trackers = active.map {
            HotkeyChordTracker(hotkey: $0.value, submitKey: submitKey, interruptionWindow: interruptionWindow)
        }
    }

    public mutating func keyDown(
        _ key: UInt16,
        isRepeat: Bool = false,
        modifiers: Set<UInt16>,
        at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        if key == Self.cancelKey, let outcome = cancelKeyDown(isRepeat: isRepeat, modifiers: modifiers) {
            return outcome
        }
        return fanOut { $0.keyDown(key, isRepeat: isRepeat, modifiers: modifiers, at: instant) }
    }

    public mutating func keyUp(
        _ key: UInt16, modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        if key == Self.cancelKey, isSwallowingCancelKey {
            isSwallowingCancelKey = false
            return Outcome(swallow: true)
        }
        return fanOut { $0.keyUp(key, modifiers: modifiers, at: instant) }
    }

    private mutating func cancelKeyDown(isRepeat: Bool, modifiers: Set<UInt16>) -> Outcome? {
        if isRepeat { return isSwallowingCancelKey ? Outcome(swallow: true) : nil }
        // A fresh key-down: a swallowed Escape's key-up still owed was lost.
        isSwallowingCancelKey = false
        guard cancelKeyEnabled else { return nil }
        let ownedByAChord = trackers.contains {
            $0.hotkey.keyCodes.contains(Self.cancelKey) || $0.submitKey.keyCodes.contains(Self.cancelKey)
        }
        guard !ownedByAChord else { return nil }
        // Only an engaged chord's modifiers: Cmd+Option+Escape is Force Quit and passes.
        let allowed = Hotkey.collapsingSides(
            Set(trackers.filter(\.isEngaged).flatMap(\.hotkey.modifierKeyCodes)))
        guard Hotkey.collapsingSides(modifiers).isSubset(of: allowed) else { return nil }
        isSwallowingCancelKey = true
        return Outcome(events: [HotkeyMonitorEvent(.escape)], swallow: true)
    }

    public mutating func flagsChanged(
        modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        fanOut { $0.flagsChanged(modifiers: modifiers, at: instant) }
    }

    public mutating func reset() -> [HotkeyMonitorEvent] {
        isSwallowingCancelKey = false
        var events: [HotkeyMonitorEvent] = []
        for index in trackers.indices {
            if let event = trackers[index].reset() {
                events.append(HotkeyMonitorEvent(role: roles[index], event: event))
            }
        }
        return events
    }

    // Every end before any press, each in role order: the gesture tracker ignores a
    // press while another chord is held, so it must hear the held chord's end first.
    private mutating func fanOut(
        _ step: (inout HotkeyChordTracker) -> HotkeyChordTracker.Outcome
    ) -> Outcome {
        var outcome = Outcome()
        var presses: [HotkeyMonitorEvent] = []
        for index in trackers.indices {
            let single = step(&trackers[index])
            if let event = single.event {
                let tagged = HotkeyMonitorEvent(role: roles[index], event: event)
                if event == .pressed { presses.append(tagged) } else { outcome.events.append(tagged) }
            }
            outcome.swallow = outcome.swallow || single.swallow
        }
        outcome.events += presses
        return outcome
    }
}
