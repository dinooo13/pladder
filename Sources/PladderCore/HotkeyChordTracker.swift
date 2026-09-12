import Foundation

/// Turns raw keyboard transitions into presses and releases of a `Hotkey`
/// chord. `GlobalHotkeyMonitor` feeds it from an event tap; tests feed it
/// directly. Pure value type, no I/O.
///
/// Rules:
/// - The chord *engages* when one of its keys goes down and, at that moment,
///   exactly the chord's modifier keys and at least the chord's regular keys are
///   held. "Exactly" is what keeps ordinary shortcuts working: Shift+Right
///   Option is not Right Option.
/// - It *disengages* when any chord key goes up, or when any other key goes
///   down (the user has started a different shortcut, so stop listening). It
///   only re-engages once one of its keys is pressed again.
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

    public init(hotkey: Hotkey, submitKey: Hotkey = Hotkey(keyCodes: [])) {
        self.hotkey = hotkey
        self.submitKey = submitKey
    }

    public mutating func keyDown(_ key: UInt16, isRepeat: Bool = false, modifiers: Set<UInt16>) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers)
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
                isEngaged = false
            }
        } else if hotkey.keyCodes.contains(key), chordIsHeld {
            isEngaged = true
            isSubmitArmed = false
            swallowedKeys.insert(key)
            swallow = true
        }
        return Outcome(event: transition(from: wasEngaged), swallow: swallow)
    }

    public mutating func keyUp(_ key: UInt16, modifiers: Set<UInt16>) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers)
        heldKeys.remove(key)
        let swallow = swallowedKeys.remove(key) != nil
        if isEngaged, hotkey.keyCodes.contains(key) { isEngaged = false }
        return Outcome(event: transition(from: wasEngaged), swallow: swallow)
    }

    public mutating func flagsChanged(modifiers: Set<UInt16>) -> Outcome {
        let wasEngaged = isEngaged
        applyModifiers(modifiers)
        return Outcome(event: transition(from: wasEngaged))
    }

    /// Forgets all held keys, releasing the chord if it was engaged. For when the
    /// event source restarts and transitions may have been missed. Events were
    /// lost, so the release never reports submit.
    public mutating func reset() -> HotkeyEvent? {
        let wasEngaged = isEngaged
        self = Self(hotkey: hotkey, submitKey: submitKey)
        return wasEngaged ? .released(submit: false) : nil
    }

    private mutating func applyModifiers(_ modifiers: Set<UInt16>) {
        let released = heldModifiers.subtracting(modifiers)
        let pressed = modifiers.subtracting(heldModifiers)
        heldModifiers = modifiers
        if isEngaged {
            let allowed = hotkey.keyCodes.union(submitKey.modifierKeyCodes)
            if !released.isDisjoint(with: hotkey.keyCodes) || !pressed.isSubset(of: allowed) {
                isEngaged = false
            } else if !pressed.isEmpty {
                armIfSubmitChordHeld()
            }
        } else if !pressed.isDisjoint(with: hotkey.keyCodes), chordIsHeld {
            isEngaged = true
            isSubmitArmed = false
        }
    }

    private var chordIsHeld: Bool {
        heldModifiers == hotkey.modifierKeyCodes && hotkey.regularKeyCodes.isSubset(of: heldKeys)
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
            return .released(submit: submit)
        }
    }
}
