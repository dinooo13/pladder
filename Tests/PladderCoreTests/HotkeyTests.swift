import Foundation
import Testing
@testable import PladderCore

private let rightOption: UInt16 = 0x3D
private let leftOption: UInt16 = 0x3A
private let leftControl: UInt16 = 0x3B
private let rightCommand: UInt16 = 0x36
private let leftCommand: UInt16 = 0x37
private let leftShift: UInt16 = 0x38
private let space: UInt16 = 0x31
private let keyA: UInt16 = 0x00
private let keyC: UInt16 = 0x08

@Suite struct HotkeyChordTrackerTests {
    @Test func loneModifierPressesAndReleases() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
    }

    @Test func leftAndRightAreDifferentKeys() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.flagsChanged(modifiers: [leftOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func modifierHeldWithAnotherModifierIsNotTheChord() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.flagsChanged(modifiers: [leftShift]) == .init())
        #expect(t.flagsChanged(modifiers: [leftShift, rightOption]) == .init())
        // Letting go of Shift leaves Right Option alone, but it was not
        // *pressed* alone: the chord only engages on a chord key going down.
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
    }

    @Test func anotherKeyWhileHeldEndsThePress() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        // Right Option + C is someone's shortcut, not dictation. Nothing is
        // swallowed, and since these instants are microseconds apart the press
        // counts as interrupted rather than released (see `InterruptionTests`).
        #expect(t.keyDown(keyA, modifiers: [rightOption]) == .init(event: .cancelled))
        #expect(t.keyUp(keyA, modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        // Same for an extra modifier.
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption, leftShift]) == .init(event: .cancelled))
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func twoModifiersTogether() {
        var t = HotkeyChordTracker(hotkey: Hotkey(rightCommand, rightOption))
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init())
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .released(submit: false)))
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func modifierPlusKeySwallowsTheKey() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        #expect(t.flagsChanged(modifiers: [leftControl]) == .init())
        #expect(t.keyDown(space, modifiers: [leftControl]) == .init(event: .pressed, swallow: true))
        #expect(t.keyDown(space, isRepeat: true, modifiers: [leftControl]) == .init(swallow: true))
        #expect(t.keyUp(space, modifiers: [leftControl]) == .init(event: .released(submit: false), swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func releasingTheModifierFirstStillSwallowsTheKeyUp() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        _ = t.flagsChanged(modifiers: [leftControl])
        #expect(t.keyDown(space, modifiers: [leftControl]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
        // Repeats keep being eaten until the key comes up, so the app never
        // sees a stream of spaces start out of nowhere.
        #expect(t.keyDown(space, isRepeat: true, modifiers: []) == .init(swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(swallow: true))
    }

    @Test func keyBeforeModifierEngagesButIsNotSwallowed() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        // The app already received this Space; it is too late to take it back.
        #expect(t.keyDown(space, modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [leftControl]) == .init(event: .pressed))
        #expect(t.keyUp(space, modifiers: [leftControl]) == .init(event: .released(submit: false), swallow: false))
    }

    @Test func plainKeyWithoutModifiers() {
        var t = HotkeyChordTracker(hotkey: Hotkey(space))
        #expect(t.keyDown(space, modifiers: []) == .init(event: .pressed, swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(event: .released(submit: false), swallow: true))
        // Shift+Space is typing, not dictation.
        #expect(t.keyDown(space, modifiers: [leftShift]) == .init())
        #expect(t.keyUp(space, modifiers: [leftShift]) == .init())
    }

    @Test func keyThatIsNotInTheChordPassesThrough() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        _ = t.flagsChanged(modifiers: [leftControl])
        #expect(t.keyDown(keyA, modifiers: [leftControl]) == .init())
        #expect(t.keyUp(keyA, modifiers: [leftControl]) == .init())
    }

    @Test func modifierAppearingOnlyInKeyFlagsIsHonoured() {
        // A key-down can carry a modifier we never saw a flagsChanged for.
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        #expect(t.keyDown(space, modifiers: [leftControl]) == .init(event: .pressed, swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(event: .released(submit: false), swallow: true))
    }

    @Test func resetReleasesAnEngagedChord() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.reset() == nil)
        _ = t.flagsChanged(modifiers: [rightOption])
        #expect(t.reset() == .released(submit: false))
        #expect(t.isEngaged == false)
        #expect(t.flagsChanged(modifiers: []) == .init())
    }
}

@Suite struct SubmitKeyTests {
    private let returnKey: UInt16 = 0x24

    @Test func submitModifierPressedWhileHeldArmsTheRelease() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
    }

    @Test func releaseOrderDoesNotMatter() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        _ = t.flagsChanged(modifiers: [rightCommand, rightOption])
        // Submit key up first: the latch holds.
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
    }

    @Test func releaseWithoutTheSubmitKeyIsNotSubmitted() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
    }

    @Test func armingIsPerPress() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        _ = t.flagsChanged(modifiers: [rightCommand, rightOption])
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
        // The latch was consumed by the release above.
        _ = t.flagsChanged(modifiers: [rightCommand])
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
    }

    @Test func regularSubmitKeyIsSwallowedWhileEngaged() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: Hotkey(returnKey))
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init(event: .pressed))
        #expect(t.keyDown(returnKey, modifiers: [rightCommand]) == .init(swallow: true))
        #expect(t.keyDown(returnKey, isRepeat: true, modifiers: [rightCommand]) == .init(swallow: true))
        #expect(t.keyUp(returnKey, modifiers: [rightCommand]) == .init(swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
    }

    @Test func submitKeyPassesThroughWhenNotEngaged() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: Hotkey(returnKey))
        #expect(t.keyDown(returnKey, modifiers: []) == .init())
        #expect(t.keyUp(returnKey, modifiers: []) == .init())
    }

    @Test func foreignModifierEndsThePressWithoutSubmit() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        #expect(t.flagsChanged(modifiers: [rightCommand, leftShift]) == .init(event: .cancelled))
    }

    @Test func emptySubmitKeyBehavesAsBefore() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init(event: .pressed))
        // Return is an ordinary key: it disengages the chord, nothing swallowed,
        // and this soon after the press that is an interruption.
        #expect(t.keyDown(returnKey, modifiers: [rightCommand]) == .init(event: .cancelled))
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func resetAfterArmingNeverSubmits() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        _ = t.flagsChanged(modifiers: [rightCommand, rightOption])
        #expect(t.reset() == .released(submit: false))
        #expect(t.isSubmitArmed == false)
    }

    @Test func submitKeyHeldBeforeTheHotkeyDoesNotEngage() {
        var t = HotkeyChordTracker(hotkey: .rightOption, submitKey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init())
        // Exactly-modifier rule: Right Command + Right Option is not Right Option,
        // so pressing Right Option last never engages the chord.
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    // MARK: The side rule

    @Test func rightOptionSpaceFiresTheOptionSpaceChord() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.keyDown(space, modifiers: [rightOption]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
        #expect(t.keyUp(space, modifiers: []) == .init(swallow: true))
    }

    @Test func shiftOptionSpaceIsNotTheChord() {
        // Sides are folded, the set is still compared exactly: an extra
        // modifier is a different chord.
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.keyDown(space, modifiers: [leftShift, leftOption]) == .init())
        #expect(t.keyUp(space, modifiers: [leftShift, leftOption]) == .init())
    }

    @Test func loneRightCommandDoesNotFireOnLeftCommand() {
        // A modifier-only chord keeps its side; that is what makes it usable.
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [leftCommand]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func spaceBeforeRightOptionEngagesButIsNotSwallowed() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.keyDown(space, modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(
            t.keyUp(space, modifiers: [rightOption])
                == .init(event: .released(submit: false), swallow: false))
    }

    @Test func aRedundantOptionLetGoDoesNotEndThePress() {
        // Both Options down, one released: the chord is still held, so the
        // release is asked of what is down rather than of what went up.
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.keyDown(space, modifiers: [rightOption]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: [rightOption, leftOption]) == .init())
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
    }

    @Test func sendKeyStillArmsWhileOptionSpaceIsHeld() {
        var t = HotkeyChordTracker(hotkey: .optionSpace, submitKey: .rightOption)
        #expect(t.keyDown(space, modifiers: [leftOption]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: [leftOption, rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
    }

    @Test func theOtherSideOfTheSendKeyStillInterrupts() {
        // The send key is matched by side even when the chord is not, so Left
        // Option is a foreign modifier here and the press is cancelled.
        let t0 = ContinuousClock.now
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space), submitKey: .rightOption)
        #expect(
            t.keyDown(space, modifiers: [leftControl], at: t0)
                == .init(event: .pressed, swallow: true))
        #expect(
            t.flagsChanged(modifiers: [leftControl, leftOption], at: t0 + .milliseconds(100))
                == .init(event: .cancelled))
    }

    @Test func sendKeyArmsOnEitherOptionWhileOptionSpaceIsHeld() {
        // Accepted quirk: Right Option is already down as part of the chord,
        // so pressing the other Option arms the send key.
        var t = HotkeyChordTracker(hotkey: .optionSpace, submitKey: .rightOption)
        #expect(t.keyDown(space, modifiers: [rightOption]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: [rightOption, leftOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: true)))
    }
}

@Suite struct HotkeyCodingTests {
    @Test func roundTripsAsSortedKeyCodes() throws {
        let hotkey = Hotkey(space, leftControl)
        let data = try JSONEncoder().encode(hotkey)
        #expect(String(decoding: data, as: UTF8.self) == #"{"keyCodes":[49,59]}"#)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
    }

    @Test func readsVersionOneModifierForm() throws {
        let json = #"{"keyCode":63,"kind":"modifier","modifiers":0}"#
        let hotkey = try JSONDecoder().decode(Hotkey.self, from: Data(json.utf8))
        #expect(hotkey == .function)
    }

    @Test func readsVersionOneKeyFormWithMask() throws {
        // NSEvent.ModifierFlags control | option, side agnostic: read as the left keys.
        let json = #"{"keyCode":49,"kind":"key","modifiers":786432}"#
        let hotkey = try JSONDecoder().decode(Hotkey.self, from: Data(json.utf8))
        #expect(hotkey == Hotkey(space, leftControl, leftOption))
    }

    @Test func classifiesModifiers() {
        #expect(Hotkey.rightOption.isModifierOnly)
        #expect(Hotkey(leftControl, space).isModifierOnly == false)
        #expect(Hotkey(leftControl, space).modifierKeyCodes == [leftControl])
        #expect(Hotkey(leftControl, space).regularKeyCodes == [space])
    }

    @Test func settingsWithEmptyChordFallBackToDefault() throws {
        let json = #"{"engineID":"echo","hotkey":{"keyCodes":[]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.hotkey == .optionSpace)
    }

    @Test func settingsWithoutHotkeyUsesOptionSpace() throws {
        let json = #"{"engineID":"echo"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.hotkey == Hotkey(leftOption, space))
    }

    @Test func settingsWithEmptySubmitKeyStaysEmpty() throws {
        // Unlike the hotkey, an empty submit chord is meaningful: it turns the
        // feature off instead of falling back to the default.
        let json = #"{"engineID":"echo","submitKey":{"keyCodes":[]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.submitKey.keyCodes.isEmpty)
    }

    @Test func settingsWithoutToggleHotkeyIsOff() throws {
        let json = #"{"engineID":"echo"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.toggleHotkey.isEmpty)
    }

    @Test func settingsWithEmptyToggleHotkeyStaysEmpty() throws {
        let json = #"{"engineID":"echo","toggleHotkey":{"keyCodes":[]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.toggleHotkey.isEmpty)
    }

    @Test func toggleHotkeyRoundTrips() throws {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.toggleHotkey = .optionSpace
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).toggleHotkey == .optionSpace)
    }
}

@Suite struct SystemWideRegistrationTests {
    private let rightShift: UInt16 = 0x3C
    private let fn: UInt16 = 0x3F
    private let f5: UInt16 = 0x60
    private let keyS: UInt16 = 0x01

    @Test func chordWithOneRegularKeyCanBeRegistered() {
        #expect(Hotkey(leftControl, space).canBeRegisteredWithoutAccessibility)
        #expect(Hotkey(space).canBeRegisteredWithoutAccessibility)
        #expect(Hotkey(leftControl, rightShift, keyA).canBeRegisteredWithoutAccessibility)
    }

    @Test func modifierOnlyChordCannot() {
        #expect(!Hotkey.rightCommand.canBeRegisteredWithoutAccessibility)
        #expect(!Hotkey(rightCommand, rightOption).canBeRegisteredWithoutAccessibility)
    }

    @Test func fnChordCannot() {
        // Carbon has no modifier bit for Fn, so the chord could only be
        // registered as a bare F5 and would fire without Fn held.
        #expect(!Hotkey(fn, f5).canBeRegisteredWithoutAccessibility)
    }

    @Test func twoRegularKeysCannot() {
        #expect(!Hotkey(leftControl, keyA, keyS).canBeRegisteredWithoutAccessibility)
    }
}

/// The one chord that stands in while Accessibility is missing, and the rule
/// that decides which chords macOS has already taken.
@Suite struct StandInRuleTests {
    private let rightControl: UInt16 = 0x3E
    private let rightShift: UInt16 = 0x3C
    private let leftCommand: UInt16 = 0x37
    private let keyD: UInt16 = 0x02
    private let fn: UInt16 = 0x3F
    private let f5: UInt16 = 0x60

    private var controlShiftSpace: Hotkey { Hotkey(leftControl, leftShift, space) }

    @Test func defaultIsOptionSpaceAndRegistrable() {
        #expect(Hotkey.optionSpace == Hotkey(leftOption, space))
        // The whole point: Carbon takes it, so it needs nothing to stand in.
        #expect(Hotkey.optionSpace.canBeRegisteredWithoutAccessibility)
        #expect(Hotkey.optionSpace.standInWithoutAccessibility == nil)
    }

    @Test func defaultIsFreeWithTwoInputSources() {
        // Command+Space, Option+Command+Space, Control+Space and
        // Control+Option+Space are the ones enabled on the developer's Mac,
        // where a second input source turns the last two on. None owns
        // Option+Space.
        let taken: Set<Hotkey> = [
            Hotkey(leftCommand, space), Hotkey(leftCommand, leftOption, space),
            Hotkey(leftControl, space), Hotkey(leftControl, leftOption, space),
        ]
        #expect(Hotkey.optionSpace.systemShortcutConflict(in: taken) == nil)
    }

    @Test func modifierOnlyChordStandsInWithTheDefault() {
        #expect(Hotkey.rightCommand.standInWithoutAccessibility == .optionSpace)
        #expect(Hotkey(rightCommand, rightOption).standInWithoutAccessibility == .optionSpace)
        // Fn has no Carbon bit, so a chord with it cannot be registered either.
        #expect(Hotkey(fn, f5).standInWithoutAccessibility == .optionSpace)
    }

    @Test func registrableChordNeedsNoStandIn() {
        #expect(Hotkey(leftControl, space).standInWithoutAccessibility == nil)
        #expect(Hotkey(rightOption, space).standInWithoutAccessibility == nil)
    }

    @Test func canonicalFoldsSidesOnlyWithARegularKey() {
        #expect(Hotkey(rightOption, space).canonical == Hotkey(leftOption, space))
        #expect(
            Hotkey(rightControl, rightShift, space).canonical
                == Hotkey(leftControl, leftShift, space))
        // A modifier-only chord is matched by side, so it keeps it.
        #expect(Hotkey.rightCommand.canonical == .rightCommand)
        #expect(
            Hotkey(rightCommand, rightOption).canonical == Hotkey(rightCommand, rightOption))
    }

    @Test func conflictNamesTheOwningShortcut() {
        #expect(
            controlShiftSpace.systemShortcutConflict(in: [Hotkey(leftControl, space)])
                == Hotkey(leftControl, space))
        // Not the other way round: that shortcut needs a modifier the chord
        // does not have, so holding the chord never triggers it.
        #expect(
            Hotkey(leftControl, space)
                .systemShortcutConflict(in: [Hotkey(leftControl, leftOption, space)]) == nil)
    }

    @Test func modifierOnlyChordNeverConflicts() {
        // Symbolic hot keys always carry a regular key, so a lone Right
        // Command cannot collide with one.
        #expect(Hotkey.rightCommand.systemShortcutConflict(in: [Hotkey(leftControl, space)]) == nil)
    }

    @Test func carbonMaskRoundTrips() {
        // 0x1000 controlKey | 0x0200 shiftKey
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x1200) == controlShiftSpace)
        #expect(controlShiftSpace.carbonModifierMask == 0x1200)
        // The right-hand keys produce the same mask, which is the whole point.
        #expect(Hotkey(rightControl, rightShift, space).carbonModifierMask == 0x1200)
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x0100) == Hotkey(leftCommand, space))
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x0800) == Hotkey(leftOption, space))
    }

    @Test func noKeyShortcutsAreNotChords() {
        // 0xFFFF is how the symbolic hot key list spells "no key assigned".
        #expect(Hotkey(keyCode: 0xFFFF, carbonModifierMask: 0x1200) == nil)
    }

    @Test func unknownMaskBitsAreIgnored() {
        // macOS sets a private bit on the function-key shortcuts; it must not
        // become a phantom modifier.
        #expect(Hotkey(keyCode: f5, carbonModifierMask: 0x21000) == Hotkey(leftControl, f5))
    }
}

/// The interruption window: another key going down just after the chord means
/// the user typed a shortcut, not a dictation. Every instant is passed in, so
/// nothing here sleeps.
@Suite struct InterruptionTests {
    private let t0 = ContinuousClock.now

    @Test func letterWithinTheWindowCancels() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        // Cmd+C. The C still reaches the app: swallowing it would break copy.
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .milliseconds(80))
                == .init(event: .cancelled))
        #expect(t.flagsChanged(modifiers: [], at: t0 + .milliseconds(200)) == .init())
    }

    @Test func letterAfterTheWindowReleases() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        // Held for a second and a half first: that was a dictation, and the
        // stray key ends it the way it always did.
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .milliseconds(1500))
                == .init(event: .released(submit: false)))
    }

    @Test func heldPastTheWindowThenReleasedTranscribes() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [], at: t0 + .seconds(3)) == .init(event: .released(submit: false)))
    }

    @Test func releaseInsideTheWindowIsStillARelease() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        // A tap of the chord alone is a (very short) dictation, not an
        // interruption: only another key going down cancels.
        #expect(
            t.flagsChanged(modifiers: [], at: t0 + .milliseconds(80))
                == .init(event: .released(submit: false)))
    }

    @Test func foreignModifierWithinTheWindowCancels() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        // Cmd+Shift+4 on its way to the screenshot tool.
        #expect(
            t.flagsChanged(modifiers: [rightCommand, leftShift], at: t0 + .milliseconds(100))
                == .init(event: .cancelled))
    }

    @Test func submitKeyIsNotAnInterruption() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption], at: t0 + .milliseconds(100)) == .init())
        #expect(
            t.flagsChanged(modifiers: [], at: t0 + .seconds(2))
                == .init(event: .released(submit: true)))
    }

    @Test func interruptedRegularKeyChordStillSwallowsItsKeyUp() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        #expect(t.flagsChanged(modifiers: [leftControl], at: t0) == .init())
        #expect(t.keyDown(space, modifiers: [leftControl], at: t0) == .init(event: .pressed, swallow: true))
        #expect(
            t.keyDown(keyA, modifiers: [leftControl], at: t0 + .milliseconds(50))
                == .init(event: .cancelled))
        // The Space we swallowed on the way down must not reach the app on the
        // way up either, cancelled press or not.
        #expect(t.keyUp(space, modifiers: [leftControl], at: t0 + .milliseconds(120)) == .init(swallow: true))
    }

    @Test func cancelClearsTheSubmitLatch() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption], at: t0 + .milliseconds(50)) == .init())
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand, rightOption], at: t0 + .milliseconds(100))
                == .init(event: .cancelled))
        #expect(t.isSubmitArmed == false)
        // The next press starts clean: no Return follows it.
        #expect(t.flagsChanged(modifiers: [], at: t0 + .milliseconds(200)) == .init())
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0 + .milliseconds(300)) == .init(event: .pressed))
        #expect(
            t.flagsChanged(modifiers: [], at: t0 + .seconds(3))
                == .init(event: .released(submit: false)))
    }

    @Test func aSecondPressRestartsTheWindow() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [], at: t0 + .seconds(5)) == .init(event: .released(submit: false)))
        // The window is measured from this press, not the first one.
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0 + .seconds(6)) == .init(event: .pressed))
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .seconds(6) + .milliseconds(80))
                == .init(event: .cancelled))
    }

    @Test func aShorterWindowIsRespected() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, interruptionWindow: .milliseconds(200))
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .milliseconds(300))
                == .init(event: .released(submit: false)))
    }
}

/// Instants are passed in; nothing sleeps.
@Suite struct HotkeyGestureTrackerTests {
    typealias Tracker = HotkeyGestureTracker
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    private static let hold: [HotkeyRole: Tracker.Mode] = [.dictate: .hold]
    private static let hybrid: [HotkeyRole: Tracker.Mode] = [.dictate: .hybrid]
    private static let twoChords: [HotkeyRole: Tracker.Mode] = [.dictate: .hold, .toggle: .toggle]

    @Test func holdModeStopsAtRelease() {
        var g = Tracker(modes: Self.hold)
        #expect(g.pressed(.dictate, at: at(0)) == .init(action: .start(.dictate)))
        #expect(g.released(.dictate, submit: false, at: at(100)) == .init(action: .stop(submit: false)))
        #expect(!g.isLatched)
    }

    @Test func submitIsCarriedThroughAHold() {
        var g = Tracker(modes: Self.hold)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: true, at: at(2_000)) == .init(action: .stop(submit: true)))
    }

    @Test func aRoleWithoutAModeHolds() {
        var g = Tracker(modes: [:])
        _ = g.pressed(.polish, at: at(0))
        #expect(g.released(.polish, submit: false, at: at(100)).action == .stop(submit: false))
    }

    @Test func toggleModeLatchesAndStopsOnTheNextPress() {
        var g = Tracker(modes: Self.twoChords)
        #expect(g.pressed(.toggle, at: at(0)) == .init(action: .start(.toggle)))
        // However long the press, a toggle chord latches.
        #expect(g.released(.toggle, submit: false, at: at(2_000)) == .init())
        #expect(g.isLatched)
        #expect(g.pressed(.toggle, at: at(9_000)) == .init(action: .stop(submit: false)))
        #expect(!g.isLatched)
    }

    @Test func hybridTapLatches() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(200)) == .init())
        #expect(g.isLatched)
        #expect(g.pressed(.dictate, at: at(5_000)) == .init(action: .stop(submit: false)))
    }

    @Test func hybridHoldStops() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(800)) == .init(action: .stop(submit: false)))
        #expect(!g.isLatched)
    }

    @Test func aReleaseAtTheThresholdIsAHold() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(400)).action == .stop(submit: false))
    }

    @Test func aShorterThresholdIsRespected() {
        var g = Tracker(modes: Self.hybrid, holdThreshold: .milliseconds(100))
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(150)).action == .stop(submit: false))
    }

    @Test func anyChordEndsALatchedRecording() {
        var g = Tracker(modes: Self.twoChords)
        _ = g.pressed(.toggle, at: at(0))
        _ = g.released(.toggle, submit: false, at: at(100))
        #expect(g.pressed(.dictate, at: at(3_000)) == .init(action: .stop(submit: false)))
    }

    @Test func theReleaseOfTheEndingPressIsIgnored() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        _ = g.released(.dictate, submit: false, at: at(100))
        _ = g.pressed(.dictate, at: at(3_000))
        #expect(g.released(.dictate, submit: true, at: at(3_100)) == .init())
        // And the next press is a fresh start.
        #expect(g.pressed(.dictate, at: at(6_000)) == .init(action: .start(.dictate)))
    }

    @Test func aSecondChordWhileHeldIsIgnored() {
        var g = Tracker(modes: Self.twoChords)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.pressed(.toggle, at: at(500)) == .init())
        #expect(g.released(.toggle, submit: false, at: at(600)) == .init())
        #expect(g.released(.dictate, submit: false, at: at(900)).action == .stop(submit: false))
    }

    @Test func interruptionDiscards() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.interrupted(.dictate) == .init(action: .discard))
        #expect(!g.isLatched)
        #expect(g.pressed(.dictate, at: at(2_000)) == .init(action: .start(.dictate)))
    }

    @Test func anotherChordsInterruptionIsIgnored() {
        // Nested chords: the other tracker's cancel is the hand-over.
        var g = Tracker(modes: Self.twoChords)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.interrupted(.toggle) == .init())
        #expect(g.released(.dictate, submit: false, at: at(900)).action == .stop(submit: false))
    }

    @Test func aBouncePressIsIgnoredAndTurnsDeferralOn() {
        var g = Tracker(modes: Self.hold)
        _ = g.pressed(.dictate, at: at(0))
        // Not deferring yet: the first bounce costs this hold.
        #expect(g.released(.dictate, submit: false, at: at(2_000)).action == .stop(submit: false))
        #expect(!g.deferReleases)
        #expect(g.pressed(.dictate, at: at(2_010)) == .init())
        #expect(g.deferReleases)
        #expect(g.released(.dictate, submit: false, at: at(2_020)) == .init())
    }

    @Test func withDeferralAReleaseSettlesFirst() {
        var g = Tracker(modes: Self.hold, deferReleases: true)
        _ = g.pressed(.dictate, at: at(0))
        #expect(
            g.released(.dictate, submit: false, at: at(2_000))
                == .init(settle: .init(token: 1, after: .milliseconds(50))))
        #expect(g.timerFired(token: 1) == .init(action: .stop(submit: false)))
        #expect(g.timerFired(token: 1) == .init())
    }

    @Test func aBounceDuringSettleResumesTheHold() {
        var g = Tracker(modes: Self.hold, deferReleases: true)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(2_000)).settle?.token == 1)
        #expect(g.pressed(.dictate, at: at(2_010)) == .init())
        #expect(g.released(.dictate, submit: false, at: at(3_000)).settle?.token == 2)
        #expect(g.timerFired(token: 1) == .init())
        #expect(g.timerFired(token: 2) == .init(action: .stop(submit: false)))
    }

    @Test func aBounceKeepsTheHoldsStart() {
        // A hybrid hold that bounced at 500 ms is still a hold, not a new tap.
        var g = Tracker(modes: Self.hybrid, deferReleases: true)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(500)).settle != nil)
        _ = g.pressed(.dictate, at: at(510))
        #expect(g.released(.dictate, submit: false, at: at(600)).settle != nil)
        #expect(!g.isLatched)
    }

    @Test func submitSurvivesABounce() {
        var g = Tracker(modes: Self.hold, deferReleases: true)
        _ = g.pressed(.dictate, at: at(0))
        _ = g.released(.dictate, submit: true, at: at(2_000))
        _ = g.pressed(.dictate, at: at(2_010))
        let token = g.released(.dictate, submit: false, at: at(3_000)).settle?.token ?? 0
        #expect(g.timerFired(token: token) == .init(action: .stop(submit: true)))
    }

    @Test func aLatchIsNeverDeferred() {
        var g = Tracker(modes: Self.hybrid, deferReleases: true)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.released(.dictate, submit: false, at: at(150)) == .init())
        #expect(g.isLatched)
    }

    @Test func aBounceNeverEndsALatch() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        _ = g.released(.dictate, submit: false, at: at(150))
        #expect(g.pressed(.dictate, at: at(160)) == .init())
        #expect(g.isLatched)
    }

    @Test func aBounceAfterTheClosingTapDoesNotStartAgain() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        _ = g.released(.dictate, submit: false, at: at(150))
        #expect(g.pressed(.dictate, at: at(4_000)).action == .stop(submit: false))
        _ = g.released(.dictate, submit: false, at: at(4_100))
        #expect(g.pressed(.dictate, at: at(4_110)) == .init())
    }

    @Test func resetKeepsDeferralAndClearsTheLatch() {
        var g = Tracker(modes: Self.hybrid)
        _ = g.pressed(.dictate, at: at(0))
        _ = g.released(.dictate, submit: false, at: at(100))
        _ = g.pressed(.dictate, at: at(110))
        #expect(g.isLatched && g.deferReleases)
        g.reset()
        #expect(!g.isLatched)
        #expect(g.deferReleases)
        #expect(g.pressed(.dictate, at: at(5_000)) == .init(action: .start(.dictate)))
    }
}
