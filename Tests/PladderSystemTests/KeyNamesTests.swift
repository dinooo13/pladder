import Foundation
import PladderCore
import Testing
@testable import PladderSystem

/// How a chord is spelled out for the user. Space is a fixed name, so none of
/// this depends on the keyboard layout the test machine happens to use.
@Suite struct KeyNamesTests {
    private let leftOption: UInt16 = 0x3A
    private let rightOption: UInt16 = 0x3D
    private let space: UInt16 = 0x31

    @Test func aChordWithARegularKeyIsNamedWithoutSides() {
        // Either Option fires the chord, so naming one would be a promise the
        // matching does not keep.
        #expect(Hotkey(rightOption, space).displayName == "Option + Space")
        #expect(Hotkey(leftOption, space).displayName == "Option + Space")
    }

    @Test func aModifierOnlyChordKeepsItsSide() {
        #expect(Hotkey.rightCommand.displayName == "Right Command")
        #expect(Hotkey.rightCommand.sideAgnosticDisplayName == "Command")
    }
}
