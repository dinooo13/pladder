import Foundation
import Testing
@testable import PladderCore

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
        var set = HotkeyChordSet(chords: [.dictate: .rightCommand, .toggle: Hotkey(leftControl, space)])
        #expect(set.flagsChanged(modifiers: [leftControl]) == .init())
        #expect(set.keyDown(space, modifiers: [leftControl]).swallow)
        #expect(set.keyUp(space, modifiers: [leftControl]).swallow)
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
        #expect(
            set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(100))
                == .init(events: [event(.dictate, .interrupted), event(.toggle, .pressed)])
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

    @Test func endsComeBeforePressesWhicheverRoleIsBuiltFirst() {
        let start = ContinuousClock.now
        var set = HotkeyChordSet(chords: [.toggle: Hotkey(rightCommand, rightOption), .dictate: .rightCommand])
        _ = set.flagsChanged(modifiers: [rightCommand], at: start)
        let handOver = set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(10))
        #expect(handOver.events == [event(.dictate, .interrupted), event(.toggle, .pressed)])
    }
}

@Suite struct ReversedNestingTests {
    private let start = ContinuousClock.now

    private func reversed() -> HotkeyChordSet {
        HotkeyChordSet(chords: [.toggle: .rightCommand, .dictate: Hotkey(rightCommand, rightOption)])
    }

    @Test func insideTheWindowTheToggleIsCancelledBeforeDictatePresses() {
        var set = reversed()
        #expect(set.flagsChanged(modifiers: [rightCommand], at: start) == .init(events: [event(.toggle, .pressed)]))
        #expect(
            set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(100))
                == .init(events: [event(.toggle, .interrupted), event(.dictate, .pressed)]))
        #expect(
            set.flagsChanged(modifiers: [], at: start + .seconds(3))
                == .init(events: [event(.dictate, .released(submit: false))]))
    }

    @Test func pastTheWindowTheToggleIsReleasedBeforeDictatePresses() {
        var set = reversed()
        _ = set.flagsChanged(modifiers: [rightCommand], at: start)
        #expect(
            set.flagsChanged(modifiers: [rightCommand, rightOption], at: start + .milliseconds(1500))
                == .init(events: [event(.toggle, .released(submit: false)), event(.dictate, .pressed)]))
    }
}
