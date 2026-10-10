import Foundation
import PladderCore
import Testing
@testable import PladderSystem

@MainActor
@Suite struct KeyNamesTests {
    private let leftOption: UInt16 = 0x3A
    private let rightOption: UInt16 = 0x3D
    private let space: UInt16 = 0x31

    @Test func aChordWithARegularKeyIsNamedWithoutSides() {
        #expect(Hotkey(rightOption, space).displayName == "Option + Space")
        #expect(Hotkey(leftOption, space).displayName == "Option + Space")
    }

    @Test func aModifierOnlyChordKeepsItsSide() {
        #expect(Hotkey.rightCommand.displayName == "Right Command")
        #expect(Hotkey.rightCommand.sideAgnosticDisplayName == "Command")
    }
}
