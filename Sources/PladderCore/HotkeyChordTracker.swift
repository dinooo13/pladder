import Foundation

/// Turns raw keyboard transitions into presses and releases of a `Hotkey`
/// chord. `GlobalHotkeyMonitor` feeds it from an event tap; tests feed it
/// directly. Pure value type, no I/O.
///
/// Rules:
/// - The chord *engages* when one of its keys goes down and, at that moment,
///   exactly the chord's modifier keys and at least the chord's regular keys are
///   held. "Exactly" is what keeps ordinary shortcuts working: Shift+Right
///   Option is not Right Option. Exactly for a modifier-only chord, that is; a
///   chord with a regular key ignores which side a modifier is on, so Right
///   Option+Space is Option+Space.
/// - It *disengages* when any chord key goes up, or when any other key goes
///   down (the user has started a different shortcut, so stop listening). It
///   only re-engages once one of its keys is pressed again.
/// - A disengage caused by another key going down within `interruptionWindow`
///   of the chord engaging is an *interruption*: the user was typing Cmd+C or
///   Cmd+Tab, not dictating, and the outcome is `.cancelled` rather than
///   `.released`. The same key pressed after the window is an ordinary
///   release, so a long hold that ends on a stray key still transcribes.
///   Interruptions need a clock, so every event takes the instant it
///   happened at; a key *up* never interrupts.
/// - A regular key whose key-down completed the chord is *swallowed*, and so are
///   its auto-repeats and its key-up, so the frontmost app never sees the Space
///   in Control+Space. Modifier events are never swallowed.
/// - The *submit key* is a second chord that may be pressed at any point while
///   the hotkey chord is engaged. Doing so *arms* the release: the resulting
///   `.released(submit: true)` asks for Return after the pasted text. The
///   submit keys themselves are swallowed (and their repeats and key-up with
///   them) so an app never sees a stray Return inside the dictation, and they
///   do not disengage the chord. When the chord is not engaged, submit keys
///   pass through to other applications untouched. Arming only happens on a
///   press event after engagement — holding the submit key before the hotkey
///   does not arm a release that never saw the submit press.
///
/// Modifier state is passed in as the full set of held modifier key codes with
/// every event rather than as individual transitions: the flags on each event
/// are authoritative, which keeps a missed event from leaving a modifier stuck.
public struct HotkeyChordTracker: Sendable, Equatable {
    public struct Outcome: Sendable, Equatable {
        /// The chord transition this event caused, if any.
        public var event: HotkeyEvent?
        /// True when the event must not reach other applications.
        public var swallow: Bool

        public init(event: HotkeyEvent? = nil, swallow: Bool = false) {
            self.event = event
            self.swallow = swallow
        }
    }

    public let hotkey: Hotkey
    /// The chord that, pressed while the hotkey chord is engaged, arms the
    /// release with `submit: true`. An empty chord means the feature is off.
    public let submitKey: Hotkey
    /// How soon after the chord engages another key still counts as an
    /// interruption. Long enough to cover a shortcut typed at speed, short
    /// enough that a deliberate hold is never mistaken for one.
    public let interruptionWindow: Duration
    public private(set) var isEngaged = false
    /// True once the submit chord has gone down during the current engagement.
    /// Reported on `.released`, then cleared.
    public private(set) var isSubmitArmed = false

    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    /// Regular keys whose key-down we swallowed. Their repeats and key-up are
    /// swallowed too, even after the chord has disengaged, so an app never sees
    /// a key-up without its key-down.
    private var swallowedKeys: Set<UInt16> = []
    /// When the current engagement began, for the interruption window.
    private var engagedAt: ContinuousClock.Instant?
    /// Set when the disengage now in progress was an interruption. Read and
    /// cleared by `transition(from:)`.
    private var wasInterrupted = false

    public init(
        hotkey: Hotkey,
        submitKey: Hotkey = Hotkey(keyCodes: []),
        interruptionWindow: Duration = .seconds(1)
    ) {
        self.hotkey = hotkey
        self.submitKey = submitKey
        self.interruptionWindow = interruptionWindow
    }

    public mutating func keyDown(
        _ key: UInt16,
        isRepeat: Bool = false,
        modifiers: Set<UInt16>,
        at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers, at: instant)
        if isRepeat {
            return Outcome(event: transition(from: wasEngaged), swallow: swallowedKeys.contains(key))
        }
        heldKeys.insert(key)
        var swallow = swallowedKeys.contains(key)
        if isEngaged {
            if submitKey.regularKeyCodes.contains(key) {
                // Part of the submit chord: swallow it so an app never sees a
                // stray Return inside the dictation, and arm if the whole
                // submit chord is now held.
                swallowedKeys.insert(key)
                swallow = true
                armIfSubmitChordHeld()
            } else if !hotkey.keyCodes.contains(key) {
                disengage(interruptedAt: instant)
            }
        } else if hotkey.keyCodes.contains(key), chordIsHeld {
            engage(at: instant)
            swallowedKeys.insert(key)
            swallow = true
        }
        return Outcome(event: transition(from: wasEngaged), swallow: swallow)
    }

    public mutating func keyUp(
        _ key: UInt16, modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers, at: instant)
        heldKeys.remove(key)
        let swallow = swallowedKeys.remove(key) != nil
        if isEngaged, hotkey.keyCodes.contains(key) { isEngaged = false }
        return Outcome(event: transition(from: wasEngaged), swallow: swallow)
    }

    public mutating func flagsChanged(
        modifiers: Set<UInt16>, at instant: ContinuousClock.Instant = .now
    ) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers, at: instant)
        return Outcome(event: transition(from: wasEngaged))
    }

    /// Forgets all held keys, releasing the chord if it was engaged. For when the
    /// event source restarts and transitions may have been missed. Events were
    /// lost, so the release never reports submit.
    public mutating func reset() -> HotkeyEvent? {
        let wasEngaged = isEngaged
        self = Self(hotkey: hotkey, submitKey: submitKey, interruptionWindow: interruptionWindow)
        return wasEngaged ? .released(submit: false) : nil
    }

    private mutating func applyModifiers(_ modifiers: Set<UInt16>, at instant: ContinuousClock.Instant) {
        let pressed = modifiers.subtracting(heldModifiers)
        heldModifiers = modifiers
        let chordModifiers = matching(hotkey.modifierKeyCodes)
        if isEngaged {
            let allowed = chordModifiers.union(matching(submitKey.modifierKeyCodes))
            if !chordModifiers.isSubset(of: matching(heldModifiers)) {
                // A chord modifier is no longer held: an ordinary release,
                // whenever it came. Asked of what is still down rather than of
                // what went up, so letting go of a redundant Left Option while
                // Right Option holds Option+Space keeps the chord engaged.
                isEngaged = false
            } else if !matching(pressed).isSubset(of: allowed) {
                // A foreign modifier went down: Shift for Cmd+Shift+4, say.
                disengage(interruptedAt: instant)
            } else if !pressed.isEmpty {
                armIfSubmitChordHeld()
            }
        } else if !matching(pressed).isDisjoint(with: chordModifiers), chordIsHeld {
            engage(at: instant)
        }
    }

    private mutating func engage(at instant: ContinuousClock.Instant) {
        isEngaged = true
        isSubmitArmed = false
        wasInterrupted = false
        engagedAt = instant
    }

    /// Disengages because another key went down. Inside the window that is an
    /// interruption and the press is cancelled rather than released.
    private mutating func disengage(interruptedAt instant: ContinuousClock.Instant) {
        isEngaged = false
        if let engagedAt, instant - engagedAt <= interruptionWindow { wasInterrupted = true }
    }

    /// Held modifiers as the chord compares them: sides folded for a chord
    /// with a regular key, exact for a modifier-only chord.
    private func matching(_ modifiers: Set<UInt16>) -> Set<UInt16> {
        hotkey.isModifierOnly ? modifiers : Hotkey.collapsingSides(modifiers)
    }

    private var chordIsHeld: Bool {
        matching(heldModifiers) == matching(hotkey.modifierKeyCodes)
            && hotkey.regularKeyCodes.isSubset(of: heldKeys)
    }

    /// The whole submit chord is held once every one of its keys is down.
    private var submitChordIsHeld: Bool {
        !submitKey.isEmpty && submitKey.keyCodes.isSubset(of: heldModifiers.union(heldKeys))
    }

    private mutating func armIfSubmitChordHeld() {
        if submitChordIsHeld { isSubmitArmed = true }
    }

    private mutating func transition(from wasEngaged: Bool) -> HotkeyEvent? {
        guard wasEngaged != isEngaged else { return nil }
        if isEngaged {
            return .pressed
        } else {
            let submit = isSubmitArmed
            isSubmitArmed = false
            engagedAt = nil
            if wasInterrupted {
                wasInterrupted = false
                return .cancelled
            }
            return .released(submit: submit)
        }
    }
}
