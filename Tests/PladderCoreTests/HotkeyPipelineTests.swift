import Foundation
import Testing
@testable import PladderCore

private struct Pipeline {
    var set: HotkeyChordSet
    var gesture: HotkeyGestureTracker

    init(chords: [HotkeyRole: Hotkey], modes: [HotkeyRole: HotkeyGestureTracker.Mode]) {
        set = HotkeyChordSet(chords: chords)
        gesture = HotkeyGestureTracker(modes: modes)
    }

    mutating func flags(_ modifiers: Set<UInt16>, at instant: ContinuousClock.Instant) -> [HotkeyGestureTracker.Action] {
        act(set.flagsChanged(modifiers: modifiers, at: instant), at: instant)
    }

    mutating func down(_ key: UInt16, _ modifiers: Set<UInt16>, at instant: ContinuousClock.Instant) -> [HotkeyGestureTracker.Action] {
        act(set.keyDown(key, modifiers: modifiers, at: instant), at: instant)
    }

    mutating func up(_ key: UInt16, _ modifiers: Set<UInt16>, at instant: ContinuousClock.Instant) -> [HotkeyGestureTracker.Action] {
        act(set.keyUp(key, modifiers: modifiers, at: instant), at: instant)
    }

    private mutating func act(_ outcome: HotkeyChordSet.Outcome, at instant: ContinuousClock.Instant) -> [HotkeyGestureTracker.Action] {
        outcome.events.compactMap { tagged in
            switch tagged.kind {
            case .chord(let role, .pressed): gesture.pressed(role, at: instant).action
            case .chord(let role, .released(let submit)): gesture.released(role, submit: submit, at: instant).action
            case .chord(let role, .cancelled): gesture.interrupted(role).action
            case .escape: nil
            }
        }
    }
}

@Suite struct HotkeyPipelineTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    private static let modes: [HotkeyRole: HotkeyGestureTracker.Mode] = [.dictate: .hold, .toggle: .toggle]

    @Test func dictateInsideTheToggleChordHandsOver() {
        var p = Pipeline(chords: [.dictate: .rightCommand, .toggle: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.dictate)])
        #expect(p.flags([rightCommand, rightOption], at: at(100)) == [.discard, .start(.toggle)])
        #expect(p.flags([], at: at(3_000)) == [])
        #expect(p.gesture.isLatched)
    }

    @Test func toggleInsideTheDictateChordHandsOver() {
        var p = Pipeline(chords: [.toggle: .rightCommand, .dictate: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.toggle)])
        #expect(p.flags([rightCommand, rightOption], at: at(100)) == [.discard, .start(.dictate)])
        #expect(p.flags([rightCommand], at: at(3_000)) == [.stop(submit: false)])
        #expect(!p.gesture.isLatched)
        #expect(p.flags([], at: at(3_100)) == [])
    }

    @Test func toggleInsideTheDictateChordPastTheWindowEndsTheToggleRecording() {
        var p = Pipeline(chords: [.toggle: .rightCommand, .dictate: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.toggle)])
        #expect(p.flags([rightCommand, rightOption], at: at(1_500)) == [.stop(submit: false)])
        #expect(!p.gesture.isLatched)
        #expect(p.flags([rightCommand], at: at(3_000)) == [])
        #expect(p.flags([], at: at(3_100)) == [])
        _ = p.flags([rightOption], at: at(5_000))
        #expect(p.flags([rightOption, rightCommand], at: at(5_010)) == [.start(.dictate)])
    }

    @Test func anOptionClickAfterALostSpaceKeyUpStartsNothing() {
        var p = Pipeline(chords: [.dictate: .optionSpace], modes: [.dictate: .hybrid])
        #expect(p.flags([leftOption], at: at(0)) == [])
        #expect(p.down(space, [leftOption], at: at(10)) == [.start(.dictate)])
        #expect(p.flags([], at: at(2_000)) == [.stop(submit: false)])
        #expect(p.flags([leftOption], at: at(5_000)) == [])
        #expect(p.flags([], at: at(5_100)) == [])
        #expect(!p.gesture.isLatched)
        #expect(p.flags([leftOption], at: at(8_000)) == [])
        #expect(p.down(space, [leftOption], at: at(8_010)) == [.start(.dictate)])
        #expect(p.up(space, [leftOption], at: at(10_000)) == [.stop(submit: false)])
    }
}
