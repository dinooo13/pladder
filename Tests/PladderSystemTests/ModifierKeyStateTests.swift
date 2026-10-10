import Foundation
import Testing
@testable import PladderSystem

@Suite struct ModifierKeyStateTests {
    private let shift: UInt64 = 0x2_0000
    private let control: UInt64 = 0x4_0000
    private let option: UInt64 = 0x8_0000
    private let command: UInt64 = 0x10_0000
    private let secondaryFn: UInt64 = 0x80_0000
    private let leftShiftBit: UInt64 = 0x2, rightShiftBit: UInt64 = 0x4
    private let leftControlBit: UInt64 = 0x1, rightControlBit: UInt64 = 0x2000
    private let leftOptionBit: UInt64 = 0x20, rightOptionBit: UInt64 = 0x40
    private let leftCommandBit: UInt64 = 0x8, rightCommandBit: UInt64 = 0x10

    private let leftShift: UInt16 = 0x38, rightShift: UInt16 = 0x3C
    private let leftControl: UInt16 = 0x3B, rightControl: UInt16 = 0x3E
    private let leftOption: UInt16 = 0x3A, rightOption: UInt16 = 0x3D
    private let leftCommand: UInt16 = 0x37, rightCommand: UInt16 = 0x36
    private let fn: UInt16 = 0x3F

    @Test func noFlagsNoModifiers() {
        #expect(ModifierKeyState().held(flags: 0).isEmpty)
    }

    @Test func deviceBitsTellTheSidesApart() {
        let state = ModifierKeyState()
        #expect(state.held(flags: option | rightOptionBit) == [rightOption])
        #expect(state.held(flags: option | leftOptionBit) == [leftOption])
        #expect(state.held(flags: command | rightCommandBit) == [rightCommand])
        #expect(state.held(flags: control | rightControlBit) == [rightControl])
        #expect(state.held(flags: shift | rightShiftBit) == [rightShift])
    }

    @Test func bothSidesAtOnce() {
        #expect(ModifierKeyState().held(flags: option | leftOptionBit | rightOptionBit) == [leftOption, rightOption])
    }

    @Test func severalModifiers() {
        let flags = control | leftControlBit | shift | rightShiftBit | command | leftCommandBit
        #expect(ModifierKeyState().held(flags: flags) == [leftControl, rightShift, leftCommand])
    }

    @Test func genericOnlyFlagsReadAsTheLeftKey() {
        let state = ModifierKeyState()
        #expect(state.held(flags: control) == [leftControl])
        #expect(state.held(flags: shift | option) == [leftShift, leftOption])
        #expect(state.held(flags: command) == [leftCommand])
    }

    @Test func aDeviceBitWithoutItsGenericBitIsIgnored() {
        #expect(ModifierKeyState().held(flags: rightOptionBit).isEmpty)
    }

    @Test func fnComesFromItsOwnFlagsChanged() {
        var state = ModifierKeyState()
        #expect(state.update(changedKey: fn, flags: secondaryFn) == [fn])
        #expect(state.held(flags: secondaryFn) == [fn])
        #expect(state.update(changedKey: fn, flags: 0) == [])
        #expect(state.held(flags: 0).isEmpty)
    }

    @Test func anArrowKeysFnFlagIsNotFn() {
        let state = ModifierKeyState()
        #expect(state.held(flags: secondaryFn).isEmpty)
        #expect(state.held(flags: secondaryFn | option | leftOptionBit) == [leftOption])
    }

    @Test func fnHeldStaysHeldAlongsideAnArrowKey() {
        var state = ModifierKeyState()
        _ = state.update(changedKey: fn, flags: secondaryFn)
        #expect(state.held(flags: secondaryFn) == [fn])
        #expect(state.update(changedKey: leftOption, flags: secondaryFn | option | leftOptionBit) == [fn, leftOption])
        _ = state.update(changedKey: fn, flags: 0)
        #expect(state.held(flags: secondaryFn).isEmpty)
    }

    @Test func anotherKeysFlagsChangedDoesNotTouchFn() {
        var state = ModifierKeyState()
        #expect(state.update(changedKey: leftShift, flags: secondaryFn | shift | leftShiftBit) == [leftShift])
    }
}
