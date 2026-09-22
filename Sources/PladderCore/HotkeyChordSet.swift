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
///
/// **The cancel key.** While `cancelKeyEnabled`, a plain Escape is reported
/// as `.escape` and swallowed, and so are its repeats and its key-up, even
/// once the cancel key has been turned off again: an app must never see a
/// key-up without its key-down. It is checked before the trackers see the
/// key, so the interruption rule never turns it into a `.cancelled` as well.
/// "Plain" allows the modifiers of an engaged chord, so Escape while
/// Option+Space is still held counts, and nothing else: Cmd+Option+Escape is
/// Force Quit and passes through. A chord or send key that contains Escape
/// keeps it as its own key.
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

    /// Set by the monitor from `setCancelKeyEnabled`; kept across `reset()`.
    public var cancelKeyEnabled = false
    /// From a swallowed Escape key-down until its key-up.
    private var isSwallowingCancelKey = false
    private static let cancelKey: UInt16 = 0x35 // kVK_Escape

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

    /// Nil when this Escape is not the cancel key and goes to the trackers
    /// like any other key.
    private mutating func cancelKeyDown(isRepeat: Bool, modifiers: Set<UInt16>) -> Outcome? {
        if isRepeat { return isSwallowingCancelKey ? Outcome(swallow: true) : nil }
        guard cancelKeyEnabled else { return nil }
        let ownedByAChord = trackers.contains {
            $0.hotkey.keyCodes.contains(Self.cancelKey) || $0.submitKey.keyCodes.contains(Self.cancelKey)
        }
        guard !ownedByAChord else { return nil }
        let allowed = Hotkey.collapsingSides(
            Set(trackers.filter(\.isEngaged).flatMap(\.hotkey.modifierKeyCodes)))
        guard Hotkey.collapsingSides(modifiers).isSubset(of: allowed) else { return nil }
        isSwallowingCancelKey = true
        return Outcome(events: [HotkeyMonitorEvent(role: .dictate, event: .escape)], swallow: true)
    }

    public mutating func flagsChanged(
        modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        fanOut { $0.flagsChanged(modifiers: modifiers, at: instant) }
    }

    /// Every engaged chord is released; events were lost, so none says submit.
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
