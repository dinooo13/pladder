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
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released))
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
        #expect(t.keyDown(keyA, modifiers: [rightOption]) == .init(event: .released))
        #expect(t.keyUp(keyA, modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
        // Same for an extra modifier.
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption, leftShift]) == .init(event: .released))
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init())
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func twoModifiersTogether() {
        var t = HotkeyChordTracker(hotkey: Hotkey(rightCommand, rightOption))
        #expect(t.flagsChanged(modifiers: [rightCommand]) == .init())
        #expect(t.flagsChanged(modifiers: [rightCommand, rightOption]) == .init(event: .pressed))
        #expect(t.flagsChanged(modifiers: [rightOption]) == .init(event: .released))
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func modifierPlusKeySwallowsTheKey() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        #expect(t.flagsChanged(modifiers: [leftControl]) == .init())
        #expect(t.keyDown(space, modifiers: [leftControl]) == .init(event: .pressed, swallow: true))
        #expect(t.keyDown(space, isRepeat: true, modifiers: [leftControl]) == .init(swallow: true))
        #expect(t.keyUp(space, modifiers: [leftControl]) == .init(event: .released, swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init())
    }

    @Test func releasingTheModifierFirstStillSwallowsTheKeyUp() {
        var t = HotkeyChordTracker(hotkey: Hotkey(leftControl, space))
        _ = t.flagsChanged(modifiers: [leftControl])
        #expect(t.keyDown(space, modifiers: [leftControl]) == .init(event: .pressed, swallow: true))
        #expect(t.flagsChanged(modifiers: []) == .init(event: .released))
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
        #expect(t.keyUp(space, modifiers: [leftControl]) == .init(event: .released, swallow: false))
    }

    @Test func plainKeyWithoutModifiers() {
        var t = HotkeyChordTracker(hotkey: Hotkey(space))
        #expect(t.keyDown(space, modifiers: []) == .init(event: .pressed, swallow: true))
        #expect(t.keyUp(space, modifiers: []) == .init(event: .released, swallow: true))
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
        #expect(t.keyUp(space, modifiers: []) == .init(event: .released, swallow: true))
    }

    @Test func resetReleasesAnEngagedChord() {
        var t = HotkeyChordTracker(hotkey: .rightOption)
        #expect(t.reset() == nil)
        _ = t.flagsChanged(modifiers: [rightOption])
        #expect(t.reset() == .released)
        #expect(t.isEngaged == false)
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
}
