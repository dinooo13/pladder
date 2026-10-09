import Foundation

// The matching rules are in docs/ARCHITECTURE.md, "Hotkeys".
public struct HotkeyChordTracker: Sendable, Equatable {
    public struct Outcome: Sendable, Equatable {
        public var event: HotkeyEvent?
        public var swallow: Bool

        public init(event: HotkeyEvent? = nil, swallow: Bool = false) {
            self.event = event
            self.swallow = swallow
        }
    }

    public let hotkey: Hotkey
    public let submitKey: Hotkey
    public let interruptionWindow: Duration
    public private(set) var isEngaged = false
    public private(set) var isSubmitArmed = false

    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    // Their repeats and key-up stay swallowed after the chord disengages: an app must
    // never see a key-up without its key-down.
    private var swallowedKeys: Set<UInt16> = []
    private var engagedAt: ContinuousClock.Instant?
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
        // Not a repeat, so a key-up still owed for this key was lost: it is taken again
        // below only if it is ours, and otherwise reaches the app.
        swallowedKeys.remove(key)
        var swallow = false
        if isEngaged {
            if submitKey.regularKeyCodes.contains(key) {
                swallowedKeys.insert(key)
                swallow = true
                armIfSubmitChordHeld()
            } else if hotkey.keyCodes.contains(key) {
                // The chord's own key down again mid-press: its key-up was lost.
                swallowedKeys.insert(key)
                swallow = true
            } else {
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

    public mutating func reset() -> HotkeyEvent? {
        let wasEngaged = isEngaged
        self = Self(hotkey: hotkey, submitKey: submitKey, interruptionWindow: interruptionWindow)
        return wasEngaged ? .released(submit: false) : nil
    }

    private mutating func applyModifiers(_ modifiers: Set<UInt16>, at instant: ContinuousClock.Instant) {
        let pressed = modifiers.subtracting(heldModifiers)
        let chordModifiers = matching(hotkey.modifierKeyCodes)
        let hadChordModifiers = chordModifiers.isSubset(of: matching(heldModifiers))
        heldModifiers = modifiers
        let hasChordModifiers = chordModifiers.isSubset(of: matching(modifiers))
        if hadChordModifiers, !hasChordModifiers {
            // A lost key-up: from here on the regular key counts only once it goes down again.
            // A modifier-less chord never gets here, so it still engages on its key alone.
            heldKeys.subtract(hotkey.regularKeyCodes)
        }
        if isEngaged {
            // The submit key is matched by side, so it is taken out before the rest is
            // folded: its other side is a foreign modifier like any other.
            let foreign = pressed.subtracting(submitKey.modifierKeyCodes)
            if !hasChordModifiers {
                // Asked of what is still down, not what went up, so letting go of a redundant
                // Left Option while Right Option holds Option+Space keeps the chord engaged.
                isEngaged = false
            } else if !matching(foreign).isSubset(of: chordModifiers) {
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

    private mutating func disengage(interruptedAt instant: ContinuousClock.Instant) {
        isEngaged = false
        if let engagedAt, instant - engagedAt <= interruptionWindow { wasInterrupted = true }
    }

    private func matching(_ modifiers: Set<UInt16>) -> Set<UInt16> {
        hotkey.isModifierOnly ? modifiers : Hotkey.collapsingSides(modifiers)
    }

    private var chordIsHeld: Bool {
        matching(heldModifiers) == matching(hotkey.modifierKeyCodes)
            && hotkey.regularKeyCodes.isSubset(of: heldKeys)
    }

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
