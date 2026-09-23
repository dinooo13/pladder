import Foundation
import Testing
@testable import PladderCore

private let rightOption: UInt16 = 0x3D
private let leftOption: UInt16 = 0x3A
private let leftControl: UInt16 = 0x3B
private let rightCommand: UInt16 = 0x36
private let space: UInt16 = 0x31
private let returnKey: UInt16 = 0x24

private func event(_ role: HotkeyRole, _ event: HotkeyEvent) -> HotkeyMonitorEvent {
    HotkeyMonitorEvent(role: role, event: event)
}

@Suite struct HotkeyChordSetTests {
    @Test func eachChordReportsItsOwnRole() {
        var set = HotkeyChordSet(chords: [.dictate: .optionSpace, .toggle: Hotkey(leftControl, space)])
        #expect(set.flagsChanged(modifiers: [leftControl]) == .init())
        #expect(set.keyDown(space, modifiers: [leftControl]) == .init(events: [event(.toggle, .pressed)], swallow: true))
        #expect(set.keyUp(space, modifiers: [leftControl]) == .init(events: [event(.toggle, .released(submit: false))], swallow: true))
        #expect(set.flagsChanged(modifiers: []) == .init())

        #expect(set.flagsChanged(modifiers: [leftOption]) == .init())
        #expect(set.keyDown(space, modifiers: [leftOption]) == .init(events: [event(.dictate, .pressed)], swallow: true))
        #expect(set.keyUp(space, modifiers: [leftOption]) == .init(events: [event(.dictate, .released(submit: false))], swallow: true))
    }

    @Test func swallowIsTheUnionOfTheTrackers() {
        // Only the polish tracker swallows the Space; the set still drops it.
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand, .toggle: Hotkey(leftControl, space)])
        #expect(set.flagsChanged(modifiers: [leftControl]) == .init())
        #expect(set.keyDown(space, modifiers: [leftControl]).swallow)
        #expect(set.keyUp(space, modifiers: [leftControl]).swallow)
        // A key neither chord owns passes through.
        #expect(!set.keyDown(0x00, modifiers: []).swallow)
    }

    @Test func anEmptyChordIsIgnored() {
        var set = HotkeyChordSet(chords: [.dictate: .optionSpace, .toggle: Hotkey(keyCodes: [])])
        var single = HotkeyChordTracker(hotkey: .optionSpace)
        #expect(set.flagsChanged(modifiers: [leftOption]) == .init())
        #expect(single.flagsChanged(modifiers: [leftOption]) == .init())
        let setDown = set.keyDown(space, modifiers: [leftOption])
        let singleDown = single.keyDown(space, modifiers: [leftOption])
        #expect(setDown == .init(events: [event(.dictate, .pressed)], swallow: true))
        #expect(singleDown == .init(event: .pressed, swallow: true))
        #expect(set.keyUp(space, modifiers: [leftOption]).events == [event(.dictate, .released(submit: false))])
    }

    @Test func nestedChordsHandOverBetweenRoles() {
        let start = ContinuousClock.now
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand, .toggle: Hotkey(rightCommand, rightOption)])
        #expect(set.flagsChanged(modifiers: [rightCommand], at: start) == .init(events: [event(.dictate, .pressed)]))
        // Right Option inside the window: the lone Right Command was the
        // start of the longer chord, not a dictation.
        #expect(
            set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(100))
                == .init(events: [event(.dictate, .cancelled), event(.toggle, .pressed)])
        )
        #expect(
            set.flagsChanged(modifiers: [], at: start + .seconds(3))
                == .init(events: [event(.toggle, .released(submit: false))])
        )
    }

    @Test func resetReleasesEveryEngagedChord() {
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand, .toggle: Hotkey(leftControl, space)])
        _ = set.flagsChanged(modifiers: [leftControl])
        _ = set.keyDown(space, modifiers: [leftControl])
        #expect(set.reset() == [event(.toggle, .released(submit: false))])
        // Nothing is engaged after a reset.
        #expect(set.reset() == [])
    }

    @Test func theSubmitKeyArmsEitherChord() {
        var set = HotkeyChordSet(
            chords: [.dictate: .rightCommand, .toggle: Hotkey(leftControl, space)],
            submitKey: Hotkey(returnKey))
        _ = set.flagsChanged(modifiers: [rightCommand])
        #expect(set.keyDown(returnKey, modifiers: [rightCommand]).swallow)
        _ = set.keyUp(returnKey, modifiers: [rightCommand])
        #expect(set.flagsChanged(modifiers: []).events == [event(.dictate, .released(submit: true))])

        _ = set.flagsChanged(modifiers: [leftControl])
        _ = set.keyDown(space, modifiers: [leftControl])
        #expect(set.keyDown(returnKey, modifiers: [leftControl]).swallow)
        _ = set.keyUp(returnKey, modifiers: [leftControl])
        #expect(set.keyUp(space, modifiers: [leftControl]).events == [event(.toggle, .released(submit: true))])
    }

    @Test func eventsComeInRoleOrder() {
        // Built in the other order; the events still come out dictate first.
        let start = ContinuousClock.now
        var set = HotkeyChordSet(chords: [.toggle: Hotkey(rightCommand, rightOption), .dictate: .rightCommand])
        _ = set.flagsChanged(modifiers: [rightCommand], at: start)
        let handOver = set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(10))
        #expect(handOver.events.map(\.role) == [.dictate, .toggle])
    }
}
