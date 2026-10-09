import Foundation
import Testing
@testable import PladderCore

/// The coordinator's hotkey loop without the coordinator: keyboard
/// transitions go into a `HotkeyChordSet`, every event it reports goes
/// through a `HotkeyGestureTracker` in the order reported, and what comes out
/// is the list of actions. That order is the contract between the two, so
/// the bugs that live in it only show with both.
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

    // MARK: Nested chords

    @Test func dictateInsideTheToggleChordHandsOver() {
        // The case that always worked: the shorter chord is dictate.
        var p = Pipeline(chords: [.dictate: .rightCommand, .toggle: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.dictate)])
        #expect(p.flags([rightCommand, rightOption], at: at(100)) == [.discard, .start(.toggle)])
        // The toggle chord latches at release; its next press stops it.
        #expect(p.flags([], at: at(3_000)) == [])
        #expect(p.gesture.isLatched)
    }

    @Test func toggleInsideTheDictateChordHandsOver() {
        // Pressing Right Command first starts the toggle chord; Right Option
        // inside the window makes it the start of the dictate chord, which
        // records until it is let go.
        var p = Pipeline(chords: [.toggle: .rightCommand, .dictate: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.toggle)])
        #expect(p.flags([rightCommand, rightOption], at: at(100)) == [.discard, .start(.dictate)])
        #expect(p.flags([rightCommand], at: at(3_000)) == [.stop(submit: false)])
        #expect(!p.gesture.isLatched)
        #expect(p.flags([], at: at(3_100)) == [])
    }

    @Test func toggleInsideTheDictateChordPastTheWindowEndsTheToggleRecording() {
        // Held past the window, Right Command alone was a toggle recording.
        // Its hand-over release latches it and the dictate press, the next
        // press of any chord, ends it: transcribed, as a dictate chord
        // inside the toggle chord would be. Nothing is left latched.
        var p = Pipeline(chords: [.toggle: .rightCommand, .dictate: Hotkey(rightCommand, rightOption)], modes: Self.modes)
        #expect(p.flags([rightCommand], at: at(0)) == [.start(.toggle)])
        #expect(p.flags([rightCommand, rightOption], at: at(1_500)) == [.stop(submit: false)])
        #expect(!p.gesture.isLatched)
        #expect(p.flags([rightCommand], at: at(3_000)) == [])
        #expect(p.flags([], at: at(3_100)) == [])
        // And the next dictate chord is a fresh start.
        _ = p.flags([rightOption], at: at(5_000))
        #expect(p.flags([rightOption, rightCommand], at: at(5_010)) == [.start(.dictate)])
    }

    // MARK: A lost key-up

    @Test func anOptionClickAfterALostSpaceKeyUpStartsNothing() {
        var p = Pipeline(chords: [.dictate: .optionSpace], modes: [.dictate: .hybrid])
        #expect(p.flags([leftOption], at: at(0)) == [])
        #expect(p.down(space, [leftOption], at: at(10)) == [.start(.dictate)])
        // Space's key-up never arrives. Letting go of Option ends the hold.
        #expect(p.flags([], at: at(2_000)) == [.stop(submit: false)])
        // An Option-click, or a short Option tap that would latch a hybrid
        // key: neither is the chord without a fresh Space.
        #expect(p.flags([leftOption], at: at(5_000)) == [])
        #expect(p.flags([], at: at(5_100)) == [])
        #expect(!p.gesture.isLatched)
        // The real chord still works.
        #expect(p.flags([leftOption], at: at(8_000)) == [])
        #expect(p.down(space, [leftOption], at: at(8_010)) == [.start(.dictate)])
        #expect(p.up(space, [leftOption], at: at(10_000)) == [.stop(submit: false)])
    }
}
