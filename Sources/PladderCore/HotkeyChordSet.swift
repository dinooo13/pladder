import Foundation

/// One `HotkeyChordTracker` per role, fed the same keyboard transitions.
/// `GlobalHotkeyMonitor` owns one behind its lock; tests drive it directly.
/// Pure value type, no I/O.
///
/// Every tracker sees every event and decides on its own, exactly as a lone
/// tracker does; an event is swallowed when any tracker swallows it. Events
/// come out in role order, so a single keystroke that moves two trackers
/// always reports them the same way round.
///
/// Two chords that nest, Right Command and Right Command + Right Option say,
/// hand over from one tracker to the other the way one tracker treats a
/// foreign modifier: pressing Right Option while Right Command is held makes
/// the first report `.cancelled` (inside the interruption window) or
/// `.released` (after it), and the second `.pressed`. The coordinator only
/// lets the chord that started a recording end it, so the hand-over's
/// release cannot cut the second recording short.
public struct HotkeyChordSet: Sendable, Equatable {
    public struct Outcome: Sendable, Equatable {
        public var events: [HotkeyMonitorEvent]
        /// True when the event must not reach other applications.
        public var swallow: Bool

        public init(events: [HotkeyMonitorEvent] = [], swallow: Bool = false) {
            self.events = events
            self.swallow = swallow
        }
    }

    /// Parallel arrays, sorted by role, so the order of events is stable and
    /// the type stays `Equatable` without a hand-written `==`.
    private let roles: [HotkeyRole]
    private var trackers: [HotkeyChordTracker]

    /// Empty chords are dropped: they never fire.
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
        fanOut { $0.keyDown(key, isRepeat: isRepeat, modifiers: modifiers, at: instant) }
    }

    public mutating func keyUp(
        _ key: UInt16, modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        fanOut { $0.keyUp(key, modifiers: modifiers, at: instant) }
    }

    public mutating func flagsChanged(
        modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        fanOut { $0.flagsChanged(modifiers: modifiers, at: instant) }
    }

    /// Every engaged chord is released; events were lost, so none says submit.
    public mutating func reset() -> [HotkeyMonitorEvent] {
        var events: [HotkeyMonitorEvent] = []
        for index in trackers.indices {
            if let event = trackers[index].reset() {
                events.append(HotkeyMonitorEvent(role: roles[index], event: event))
            }
        }
        return events
    }

    private mutating func fanOut(
        _ step: (inout HotkeyChordTracker) -> HotkeyChordTracker.Outcome
    ) -> Outcome {
        var outcome = Outcome()
        for index in trackers.indices {
            let single = step(&trackers[index])
            if let event = single.event {
                outcome.events.append(HotkeyMonitorEvent(role: roles[index], event: event))
            }
            outcome.swallow = outcome.swallow || single.swallow
        }
        return outcome
    }
}
