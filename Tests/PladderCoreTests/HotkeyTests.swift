import Foundation
import Testing
@testable import PladderCore

let rightOption: UInt16 = 0x3D
let leftOption: UInt16 = 0x3A
let leftControl: UInt16 = 0x3B
let rightControl: UInt16 = 0x3E
let rightCommand: UInt16 = 0x36
let leftCommand: UInt16 = 0x37
let leftShift: UInt16 = 0x38
let rightShift: UInt16 = 0x3C
let fn: UInt16 = 0x3F
let space: UInt16 = 0x31
let returnKey: UInt16 = 0x24
let escapeKey: UInt16 = 0x35
let f5: UInt16 = 0x60
let keyA: UInt16 = 0x00
let keyS: UInt16 = 0x01
let keyD: UInt16 = 0x02
let keyC: UInt16 = 0x08
let keyV: UInt16 = 0x09

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
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
    }

    @Test func anotherKeyWhileHeldEndsThePress() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.keyDown(keyA, modifiers: [rightOption]) == .init(event: .interrupted))
        #expect(t.keyUp(keyA, modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption, leftShift]) == .init(event: .interrupted))
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
        #expect(t.keyDown(space, isRepeat: true, modifiers: []) == .init(swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(swallow: true))
    }

    @Test func keyBeforeModifierEngagesButIsNotSwallowed() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        #expect(t.keyDown(space, modifiers: []) == .init())
        #expect(t.flagsChanged(modifiers: [leftControl]) == .init(event: .pressed))
        #expect(t.keyUp(space, modifiers: [leftControl]) == .init(event: .released(submit: false), swallow: false))
    }

    @Test func plainKeyWithoutModifiers() {
        var t = HotkeyChordTracker(hotkey: Hotkey(space))
        #expect(t.keyDown(space, modifiers: []) == .init(event: .pressed, swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(event: .released(submit: false), swallow: true))
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

    @Test func defaultSubmitKeyWorksWithTheHandHoldingTheChord() {
        var t = HotkeyChordTracker(hotkey: .optionSpace, submitKey: .keyV)
        #expect(t.flagsChanged(modifiers: [leftOption]) == .init())
        #expect(t.keyDown(space, modifiers: [leftOption]) == .init(event: .pressed, swallow: true))
        #expect(t.keyDown(keyV, modifiers: [leftOption]) == .init(swallow: true))
        #expect(t.keyUp(keyV, modifiers: [leftOption]) == .init(swallow: true))
        #expect(t.keyUp(space, modifiers: [leftOption]) == .init(event: .released(submit: true), swallow: true))
        #expect(t.keyDown(keyV, modifiers: []) == .init())
        #expect(t.keyUp(keyV, modifiers: []) == .init())
    }

    @Test func submitKeyPassesThroughWhenNotEngaged() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: Hotkey(returnKey))
        #expect(t.keyDown(returnKey, modifiers: []) == .init())
        #expect(t.keyUp(returnKey, modifiers: []) == .init())
    }

    @Test func foreignModifierEndsThePressWithoutSubmit() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        _ = t.flagsChanged(modifiers: [rightCommand])
        #expect(t.flagsChanged(modifiers: [rightCommand, leftShift]) == .init(event: .interrupted))
    }

    @Test func emptySubmitKeyBehavesAsBefore() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init(event: .pressed))
        #expect(t.keyDown(returnKey, modifiers: [rightCommand]) == .init(event: .interrupted))
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
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func rightOptionSpaceFiresTheOptionSpaceChord() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.keyDown(space, modifiers: [rightOption]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released(submit: false)))
        #expect(t.keyUp(space, modifiers: []) == .init(swallow: true))
    }

    @Test func shiftOptionSpaceIsNotTheChord() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(t.keyDown(space, modifiers: [leftShift, leftOption]) == .init())
        #expect(t.keyUp(space, modifiers: [leftShift, leftOption]) == .init())
    }

    @Test func loneRightCommandDoesNotFireOnLeftCommand() {
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
        let t0 = ContinuousClock.now
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space), submitKey: .rightOption)
        #expect(
            t.keyDown(space, modifiers: [leftControl], at: t0)
                == .init(event: .pressed, swallow: true))
        #expect(
            t.flagsChanged(modifiers: [leftControl, leftOption], at: t0 + .milliseconds(100))
                == .init(event: .interrupted))
    }

    @Test func sendKeyArmsOnEitherOptionWhileOptionSpaceIsHeld() {
        // Accepted quirk: Right Option is already down as part of the chord, so pressing the
        // other Option arms the send key.
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
        #expect(hotkey == Hotkey(0x3F))  // Fn
    }

    @Test func readsVersionOneKeyFormWithMask() throws {
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
        #expect(!Hotkey(fn, f5).canBeRegisteredWithoutAccessibility)
    }

    @Test func twoRegularKeysCannot() {
        #expect(!Hotkey(leftControl, keyA, keyS).canBeRegisteredWithoutAccessibility)
    }
}

@Suite struct StandInRuleTests {

    private var controlShiftSpace: Hotkey { Hotkey(leftControl, leftShift, space) }

    @Test func defaultIsOptionSpaceAndRegistrable() {
        #expect(Hotkey.optionSpace == Hotkey(leftOption, space))
        #expect(Hotkey.optionSpace.canBeRegisteredWithoutAccessibility)
        #expect(Hotkey.optionSpace.standInWithoutAccessibility == nil)
    }

    @Test func defaultIsFreeWithTwoInputSources() {
        // The shortcuts enabled on the developer's Mac, where a second input source turns on
        // the two Control ones.
        let taken: Set<Hotkey> = [
            Hotkey(leftCommand, space), Hotkey(leftCommand, leftOption, space),
            Hotkey(leftControl, space), Hotkey(leftControl, leftOption, space),
        ]
        #expect(Hotkey.optionSpace.systemShortcutConflict(in: taken) == nil)
    }

    @Test func modifierOnlyChordStandsInWithTheDefault() {
        #expect(Hotkey.rightCommand.standInWithoutAccessibility == .optionSpace)
        #expect(Hotkey(rightCommand, rightOption).standInWithoutAccessibility == .optionSpace)
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
        #expect(Hotkey.rightCommand.canonical == .rightCommand)
        #expect(
            Hotkey(rightCommand, rightOption).canonical == Hotkey(rightCommand, rightOption))
    }

    @Test func conflictNamesTheOwningShortcut() {
        #expect(
            controlShiftSpace.systemShortcutConflict(in: [Hotkey(leftControl, space)])
                == Hotkey(leftControl, space))
        #expect(
            Hotkey(leftControl, space)
                .systemShortcutConflict(in: [Hotkey(leftControl, leftOption, space)]) == nil)
    }

    @Test func modifierOnlyChordNeverConflicts() {
        #expect(Hotkey.rightCommand.systemShortcutConflict(in: [Hotkey(leftControl, space)]) == nil)
    }

    @Test func carbonMaskRoundTrips() {
        // 0x1000 controlKey | 0x0200 shiftKey
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x1200) == controlShiftSpace)
        #expect(controlShiftSpace.carbonModifierMask == 0x1200)
        #expect(Hotkey(rightControl, rightShift, space).carbonModifierMask == 0x1200)
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x0100) == Hotkey(leftCommand, space))
        #expect(Hotkey(keyCode: space, carbonModifierMask: 0x0800) == Hotkey(leftOption, space))
    }

    @Test func noKeyShortcutsAreNotChords() {
        #expect(Hotkey(keyCode: 0xFFFF, carbonModifierMask: 0x1200) == nil)
    }

    @Test func unknownMaskBitsAreIgnored() {
        // macOS sets a private bit on the function-key shortcuts.
        #expect(Hotkey(keyCode: f5, carbonModifierMask: 0x21000) == Hotkey(leftControl, f5))
    }
}

@Suite struct InterruptionTests {
    private let t0 = ContinuousClock.now

    @Test func letterWithinTheWindowCancels() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .milliseconds(80))
                == .init(event: .interrupted))
        #expect(t.flagsChanged(modifiers: [], at: t0 + .milliseconds(200)) == .init())
    }

    @Test func letterAfterTheWindowReleases() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
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
        #expect(
            t.flagsChanged(modifiers: [], at: t0 + .milliseconds(80))
                == .init(event: .released(submit: false)))
    }

    @Test func foreignModifierWithinTheWindowCancels() {
        var t = HotkeyChordTracker(hotkey: .rightCommand)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(
            t.flagsChanged(modifiers: [rightCommand, leftShift], at: t0 + .milliseconds(100))
                == .init(event: .interrupted))
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
                == .init(event: .interrupted))
        #expect(t.keyUp(space, modifiers: [leftControl], at: t0 + .milliseconds(120)) == .init(swallow: true))
    }

    @Test func cancelClearsTheSubmitLatch() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, submitKey: .rightOption)
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption], at: t0 + .milliseconds(50)) == .init())
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand, rightOption], at: t0 + .milliseconds(100))
                == .init(event: .interrupted))
        #expect(t.isSubmitArmed == false)
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
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0 + .seconds(6)) == .init(event: .pressed))
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .seconds(6) + .milliseconds(80))
                == .init(event: .interrupted))
    }

    @Test func aShorterWindowIsRespected() {
        var t = HotkeyChordTracker(hotkey: .rightCommand, interruptionWindow: .milliseconds(200))
        #expect(t.flagsChanged(modifiers: [rightCommand], at: t0) == .init(event: .pressed))
        #expect(
            t.keyDown(keyC, modifiers: [rightCommand], at: t0 + .milliseconds(300))
                == .init(event: .released(submit: false)))
    }
}

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
        _ = g.pressed(.toggle, at: at(0))
        #expect(g.released(.toggle, submit: false, at: at(100)).action == .stop(submit: false))
    }

    @Test func toggleModeLatchesAndStopsOnTheNextPress() {
        var g = Tracker(modes: Self.twoChords)
        #expect(g.pressed(.toggle, at: at(0)) == .init(action: .start(.toggle)))
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
        var g = Tracker(modes: Self.twoChords)
        _ = g.pressed(.dictate, at: at(0))
        #expect(g.interrupted(.toggle) == .init())
        #expect(g.released(.dictate, submit: false, at: at(900)).action == .stop(submit: false))
    }

    @Test func aDictateChordInsideTheToggleChordHandsOver() {
        var g = Tracker(modes: Self.twoChords)
        #expect(g.pressed(.dictate, at: at(0)) == .init(action: .start(.dictate)))
        #expect(g.interrupted(.dictate) == .init(action: .discard))
        #expect(g.pressed(.toggle, at: at(100)) == .init(action: .start(.toggle)))
    }

    @Test func aToggleChordInsideTheDictateChordHandsOver() {
        var g = Tracker(modes: Self.twoChords)
        #expect(g.pressed(.toggle, at: at(0)) == .init(action: .start(.toggle)))
        #expect(g.interrupted(.toggle) == .init(action: .discard))
        #expect(g.pressed(.dictate, at: at(100)) == .init(action: .start(.dictate)))
        #expect(g.released(.dictate, submit: false, at: at(3_000)) == .init(action: .stop(submit: false)))
        #expect(!g.isLatched)
    }

    @Test func pastTheWindowAToggleChordsHandOverEndsItsRecording() {
        var g = Tracker(modes: Self.twoChords)
        _ = g.pressed(.toggle, at: at(0))
        #expect(g.released(.toggle, submit: false, at: at(1_500)) == .init())
        #expect(g.pressed(.dictate, at: at(1_500)) == .init(action: .stop(submit: false)))
        #expect(!g.isLatched)
        #expect(g.released(.dictate, submit: false, at: at(3_000)) == .init())
    }

    @Test func aBouncePressIsIgnoredAndTurnsDeferralOn() {
        var g = Tracker(modes: Self.hold)
        _ = g.pressed(.dictate, at: at(0))
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

@Suite struct CancelKeyTests {
    private static let escape = [HotkeyMonitorEvent(.escape)]

    private func optionSpaceSet() -> HotkeyChordSet {
        HotkeyChordSet(chords: [.dictate: .optionSpace, .toggle: Hotkey(leftControl, 0x02)])
    }

    @Test func escapeIsTheCancelKeyOnlyWhileEnabled() {
        var set = optionSpaceSet()
        #expect(set.keyDown(escapeKey, modifiers: []) == .init())
        #expect(set.keyUp(escapeKey, modifiers: []) == .init())
        set.cancelKeyEnabled = true
        #expect(set.keyDown(escapeKey, modifiers: []) == .init(events: Self.escape, swallow: true))
        #expect(set.keyDown(escapeKey, isRepeat: true, modifiers: []) == .init(swallow: true))
        #expect(set.keyUp(escapeKey, modifiers: []) == .init(swallow: true))
        #expect(set.keyDown(escapeKey, modifiers: []).events == Self.escape)
    }

    @Test func escapeKeyUpIsSwallowedAfterDisabling() {
        var set = optionSpaceSet()
        set.cancelKeyEnabled = true
        _ = set.keyDown(escapeKey, modifiers: [])
        set.cancelKeyEnabled = false
        #expect(set.keyDown(escapeKey, isRepeat: true, modifiers: []) == .init(swallow: true))
        #expect(set.keyUp(escapeKey, modifiers: []) == .init(swallow: true))
        #expect(set.keyDown(escapeKey, modifiers: []) == .init())
    }

    @Test func escapeWithForeignModifiersPassesThrough() {
        var set = optionSpaceSet()
        set.cancelKeyEnabled = true
        _ = set.flagsChanged(modifiers: [leftCommand, leftOption])
        #expect(set.keyDown(escapeKey, modifiers: [leftCommand, leftOption]) == .init())
        #expect(set.keyUp(escapeKey, modifiers: [leftCommand, leftOption]) == .init())
    }

    @Test func escapeWithTheChordsOwnModifiersCancels() {
        var set = optionSpaceSet()
        set.cancelKeyEnabled = true
        _ = set.flagsChanged(modifiers: [rightOption])
        #expect(set.keyDown(space, modifiers: [rightOption]).events == [HotkeyMonitorEvent(role: .dictate, event: .pressed)])
        #expect(set.keyDown(escapeKey, modifiers: [rightOption]) == .init(events: Self.escape, swallow: true))
    }

    @Test func escapeNeverReachesTheChordTrackers() {
        let start = ContinuousClock.now
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand])
        set.cancelKeyEnabled = true
        _ = set.flagsChanged(modifiers: [rightCommand], at: start)
        #expect(
            set.keyDown(escapeKey, modifiers: [rightCommand], at: start + .milliseconds(100))
                == .init(events: Self.escape, swallow: true))
        #expect(set.keyUp(escapeKey, modifiers: [rightCommand], at: start + .milliseconds(150)) == .init(swallow: true))
        #expect(
            set.flagsChanged(modifiers: [], at: start + .seconds(3)).events
                == [HotkeyMonitorEvent(role: .dictate, event: .released(submit: false))])
    }

    @Test func aChordContainingEscapeIsNotTheCancelKey() {
        var set = HotkeyChordSet(chords: [.dictate: Hotkey(leftOption, escapeKey)])
        set.cancelKeyEnabled = true
        _ = set.flagsChanged(modifiers: [leftOption])
        #expect(
            set.keyDown(escapeKey, modifiers: [leftOption])
                == .init(events: [HotkeyMonitorEvent(role: .dictate, event: .pressed)], swallow: true))
    }

    @Test func aSendKeyContainingEscapeIsNotTheCancelKey() {
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand], submitKey: Hotkey(escapeKey))
        set.cancelKeyEnabled = true
        _ = set.flagsChanged(modifiers: [rightCommand])
        #expect(set.keyDown(escapeKey, modifiers: [rightCommand]) == .init(swallow: true))
        _ = set.keyUp(escapeKey, modifiers: [rightCommand])
        #expect(set.flagsChanged(modifiers: []).events == [HotkeyMonitorEvent(role: .dictate, event: .released(submit: true))])
    }

    @Test func aLostEscapeKeyUpDoesNotEatTheNextOne() {
        var set = optionSpaceSet()
        set.cancelKeyEnabled = true
        _ = set.keyDown(escapeKey, modifiers: [])
        set.cancelKeyEnabled = false
        #expect(set.keyDown(escapeKey, modifiers: []) == .init())
        #expect(set.keyUp(escapeKey, modifiers: []) == .init())
    }

    @Test func resetKeepsTheCancelKey() {
        var set = optionSpaceSet()
        set.cancelKeyEnabled = true
        _ = set.reset()
        #expect(set.cancelKeyEnabled)
        #expect(set.keyDown(escapeKey, modifiers: []).events == Self.escape)
    }
}

@Suite struct LostKeyUpTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    private func afterALostSpaceKeyUp() -> HotkeyChordTracker {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        _ = t.flagsChanged(modifiers: [leftOption], at: at(0))
        _ = t.keyDown(space, modifiers: [leftOption], at: at(10))
        _ = t.flagsChanged(modifiers: [], at: at(2_000))
        return t
    }

    @Test func letGoOfOptionReleasesAndOnlyARealOptionSpacePressesAgain() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        _ = t.flagsChanged(modifiers: [leftOption], at: at(0))
        #expect(t.keyDown(space, modifiers: [leftOption], at: at(10)) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: [], at: at(2_000)) == .init(event: .released(submit: false)))
        #expect(t.flagsChanged(modifiers: [rightOption], at: at(4_000)) == .init())
        #expect(t.flagsChanged(modifiers: [], at: at(4_100)) == .init())
        #expect(t.flagsChanged(modifiers: [leftOption], at: at(5_000)) == .init())
        #expect(t.keyDown(space, modifiers: [leftOption], at: at(5_010)) == .init(event: .pressed, swallow: true))
        #expect(t.keyUp(space, modifiers: [leftOption], at: at(7_000)) == .init(event: .released(submit: false), swallow: true))
        #expect(t.flagsChanged(modifiers: [], at: at(7_100)) == .init())
    }

    @Test func theNextSpaceIsTypedNormally() {
        var t = afterALostSpaceKeyUp()
        #expect(t.keyDown(space, modifiers: [], at: at(5_000)) == .init())
        #expect(t.keyUp(space, modifiers: [], at: at(5_050)) == .init())
    }

    @Test func aFreshKeyDownWhileEngagedKeepsThePress() {
        var t = HotkeyChordTracker(hotkey: .optionSpace)
        _ = t.flagsChanged(modifiers: [leftOption], at: at(0))
        _ = t.keyDown(space, modifiers: [leftOption], at: at(10))
        #expect(t.keyDown(space, modifiers: [leftOption], at: at(1_500)) == .init(swallow: true))
        #expect(t.isEngaged)
        #expect(t.keyUp(space, modifiers: [leftOption], at: at(3_000)) == .init(event: .released(submit: false), swallow: true))
    }

    @Test func aChordWithTwoModifiersAlsoForgetsTheKey() {
        let controlShiftSpace = Hotkey(leftControl, leftShift, space)
        var t = HotkeyChordTracker(hotkey: controlShiftSpace)
        _ = t.flagsChanged(modifiers: [leftControl, leftShift], at: at(0))
        #expect(t.keyDown(space, modifiers: [leftControl, leftShift], at: at(10)) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: [leftControl], at: at(2_000)) == .init(event: .released(submit: false)))
        #expect(t.flagsChanged(modifiers: [leftControl, leftShift], at: at(4_000)) == .init())
    }
}
