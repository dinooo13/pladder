import Foundation
import Testing
@testable import PladderCore

private let rightOption: UInt16 = 0x3D
private let leftOption: UInt16 = 0x3A
private let leftControl: UInt16 = 0x3B
private let rightCommand: UInt16 = 0x36
private let leftShift: UInt16 = 0x38
private let space: UInt16 = 0x31
private let keyA: UInt16 = 0x00

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
        // Right Option + C is someone's shortcut, not dictation. Nothing is swallowed.
        #expect(t.keyDown(keyA, modifiers: [rightOption]) == .init(event: .released(submit: false)))
        #expect(t.keyUp(keyA, modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        // Same for an extra modifier.
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption, leftShift]) == .init(event: .released(submit: false)))
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
        #expect(t.flagsChanged(modifiers: [rightCommand, leftShift]) == .init(event: .released(submit: false)))
    }

    @Test func emptySubmitKeyBehavesAsBefore() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init(event: .pressed))
        // Return is an ordinary key: it disengages the chord, nothing swallowed.
        #expect(t.keyDown(returnKey, modifiers: [rightCommand]) == .init(event: .released(submit: false)))
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
        #expect(settings.hotkey == .rightCommand)
    }

    @Test func settingsWithEmptySubmitKeyStaysEmpty() throws {
        // Unlike the hotkey, an empty submit chord is meaningful: it turns the
        // feature off instead of falling back to the default.
        let json = #"{"engineID":"echo","submitKey":{"keyCodes":[]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.submitKey.keyCodes.isEmpty)
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
