import Foundation
import Testing
@testable import PladderCore

@Suite struct HotkeySourceTests {
    private let registrable = Hotkey.optionSpace
    private let modifierOnly = Hotkey.rightCommand
    private let withFn = Hotkey(0x3F, 0x60)  // Fn + F5

    @Test func withoutAccessibilityItIsAlwaysCarbon() {
        for chord in [registrable, modifierOnly, withFn] {
            for sustained in [false, true] {
                #expect(HotkeySource.choose(accessibilityTrusted: false, secureInputSustained: sustained, hotkey: chord) == .carbon)
            }
        }
    }

    @Test func withAccessibilityItIsTheTap() {
        for chord in [registrable, modifierOnly, withFn] {
            #expect(HotkeySource.choose(accessibilityTrusted: true, secureInputSustained: false, hotkey: chord) == .tap)
        }
    }

    @Test func sustainedSecureInputMovesARegistrableChordToCarbon() {
        #expect(HotkeySource.choose(accessibilityTrusted: true, secureInputSustained: true, hotkey: registrable) == .carbon)
    }

    @Test func sustainedSecureInputLeavesAChordCarbonCannotTakeOnTheTap() {
        #expect(HotkeySource.choose(accessibilityTrusted: true, secureInputSustained: true, hotkey: modifierOnly) == .tap)
        #expect(HotkeySource.choose(accessibilityTrusted: true, secureInputSustained: true, hotkey: withFn) == .tap)
    }
}
