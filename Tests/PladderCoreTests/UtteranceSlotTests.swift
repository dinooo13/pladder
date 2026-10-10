import Foundation
import Testing
@testable import PladderCore

@Suite struct UtteranceSlotTests {
    @Test func aBeginHandsBackTheSessionItReplaces() {
        var slot = UtteranceSlot<String>()
        let first = slot.begin()
        #expect(first.replaced == nil)
        let installed = slot.install("first", for: first.utterance)
        #expect(installed)
        let second = slot.begin()
        #expect(second.utterance != first.utterance)
        #expect(second.replaced == "first")
        #expect(slot.session(for: second.utterance) == nil)
    }

    @Test func aStaleHandleLeavesTheCurrentUtteranceAlone() {
        var slot = UtteranceSlot<String>()
        let old = slot.begin().utterance
        _ = slot.install("old", for: old)
        let current = slot.begin().utterance
        let installed = slot.install("current", for: current)
        #expect(installed)
        #expect(slot.session(for: old) == nil)
        let released = slot.release(old)
        #expect(!released.wasCurrent)
        #expect(released.session == nil)
        #expect(slot.current == current)
        #expect(slot.session(for: current) == "current")
    }

    @Test func aBeginOvertakenByAnotherIsRefusedItsSession() {
        var slot = UtteranceSlot<String>()
        let overtaken = slot.begin().utterance
        let latest = slot.begin().utterance
        let latestInstalled = slot.install("latest", for: latest)
        let overtakenInstalled = slot.install("overtaken", for: overtaken)
        #expect(latestInstalled)
        #expect(!overtakenInstalled)
        #expect(slot.session(for: latest) == "latest")
    }

    @Test func anUtteranceAbandonedWhileItBeginsIsRefusedItsSession() {
        var slot = UtteranceSlot<String>()
        let utterance = slot.begin().utterance
        let released = slot.release(utterance)
        #expect(released.wasCurrent)
        #expect(released.session == nil)
        let installed = slot.install("late", for: utterance)
        #expect(!installed)
        #expect(slot.current == nil)
    }

    @Test func releasingTheCurrentUtteranceHandsBackItsSessionOnce() {
        var slot = UtteranceSlot<String>()
        let utterance = slot.begin().utterance
        _ = slot.install("session", for: utterance)
        let first = slot.release(utterance)
        let second = slot.release(utterance)
        #expect(first.wasCurrent)
        #expect(first.session == "session")
        #expect(!second.wasCurrent)
        #expect(slot.current == nil)
    }
}
