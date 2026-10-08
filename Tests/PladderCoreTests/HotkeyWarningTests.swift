import Testing
@testable import PladderCore

@Suite struct HotkeyWarningTests {
    private let space: UInt16 = 0x31
    private let leftCommand: UInt16 = 0x37
    private let leftControl: UInt16 = 0x3B

    @Test func theStandInIsNamedUnlessMacOSOwnsIt() {
        let stored = Hotkey.rightCommand
        #expect(HotkeyWarning.forKey(stored, standIn: .optionSpace, systemShortcuts: [])
            == .standIn(stored: stored, standIn: .optionSpace))
        #expect(HotkeyWarning.forKey(stored, standIn: .optionSpace, systemShortcuts: [.optionSpace])
            == .systemShortcut(owner: .optionSpace, chord: .optionSpace))
    }

    @Test func aChordMacOSOwnsIsWarnedAbout() {
        let spotlight = Hotkey(leftCommand, space)
        #expect(HotkeyWarning.forKey(spotlight, standIn: nil, systemShortcuts: [spotlight])
            == .systemShortcut(owner: spotlight, chord: spotlight))
    }

    @Test func aChordWithoutAModifierIsWarnedAboutAndAModifierOnlyOneIsNot() {
        #expect(HotkeyWarning.forKey(Hotkey(space), standIn: nil, systemShortcuts: []) == .noModifier(Hotkey(space)))
        #expect(HotkeyWarning.forKey(.rightCommand, standIn: nil, systemShortcuts: []) == nil)
        #expect(HotkeyWarning.forKey(.optionSpace, standIn: nil, systemShortcuts: []) == nil)
    }

    @Test func aHybridOrEmptyToggleNeedsNoWarning() {
        let off = Hotkey(keyCodes: [])
        #expect(HotkeyWarning.forToggle(off, hotkey: .optionSpace, accessibilityTrusted: false, systemShortcuts: []) == nil)
        #expect(HotkeyWarning.forToggle(.optionSpace, hotkey: .optionSpace, accessibilityTrusted: false, systemShortcuts: []) == nil)
    }

    @Test func aModifierOnlyToggleNeedsAccessibility() {
        #expect(HotkeyWarning.forToggle(.rightCommand, hotkey: .optionSpace, accessibilityTrusted: false, systemShortcuts: [])
            == .toggleNeedsAccessibility(.rightCommand))
        #expect(HotkeyWarning.forToggle(.rightCommand, hotkey: .optionSpace, accessibilityTrusted: true, systemShortcuts: []) == nil)
    }

    @Test func theSendKeyNeedsAccessibilityAndAKeyOfItsOwn() {
        #expect(HotkeyWarning.forSendKey(.keyV, hotkey: .optionSpace, accessibilityTrusted: false) == .sendKeyNeedsAccessibility)
        #expect(HotkeyWarning.forSendKey(Hotkey(space), hotkey: .optionSpace, accessibilityTrusted: true)
            == .sendKeyInsideChord(Hotkey(space)))
        #expect(HotkeyWarning.forSendKey(.keyV, hotkey: .optionSpace, accessibilityTrusted: true) == nil)
        #expect(HotkeyWarning.forSendKey(Hotkey(keyCodes: []), hotkey: .optionSpace, accessibilityTrusted: false) == nil)
    }

    @Test func aControlChordIsNotModifierless() {
        #expect(HotkeyWarning.forKey(Hotkey(leftControl, space), standIn: nil, systemShortcuts: []) == nil)
    }
}
