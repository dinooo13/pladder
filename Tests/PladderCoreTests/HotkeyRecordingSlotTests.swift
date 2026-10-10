import Foundation
import Testing
@testable import PladderCore

@MainActor
private final class FakeRecorder {
    var cancelled = 0
}

@MainActor
@Suite struct HotkeyRecordingSlotTests {
    private func makeSlot() -> HotkeyRecordingSlot<FakeRecorder> {
        HotkeyRecordingSlot { $0.cancelled += 1 }
    }

    @Test func aSecondRecorderCancelsTheFirstAndOnlyTheLastResumes() {
        let slot = makeSlot()
        var calls: [Bool] = []
        let a = FakeRecorder(), b = FakeRecorder()
        let ta = slot.makeToken(), tb = slot.makeToken()
        slot.claim(ta, by: a) { calls.append($0) }
        slot.claim(tb, by: b) { calls.append($0) }
        #expect(a.cancelled == 1)
        slot.release(ta)
        #expect(calls == [true])
        slot.release(tb)
        #expect(calls == [true, false])
        #expect(!slot.isSuspended)
    }

    @Test func aRecorderFreedWhileRecordingHandsTheSessionOver() {
        let slot = makeSlot()
        var calls: [Bool] = []
        var gone: FakeRecorder? = FakeRecorder()
        let stale = slot.makeToken()
        slot.claim(stale, by: gone!) { calls.append($0) }
        gone = nil
        #expect(slot.isSuspended)

        let next = FakeRecorder()
        let token = slot.makeToken()
        slot.claim(token, by: next) { calls.append($0) }
        #expect(slot.isSuspended)
        slot.release(stale)
        #expect(slot.isSuspended)
        slot.release(token)
        #expect(!slot.isSuspended)
        #expect(calls.last == false)
    }

    @Test func aFreedRecordersOwnReleaseResumesTheHotkey() {
        let slot = makeSlot()
        var calls: [Bool] = []
        let token = slot.makeToken()
        do {
            let recorder = FakeRecorder()
            slot.claim(token, by: recorder) { calls.append($0) }
        }
        slot.release(token)
        #expect(calls == [true, false])
        #expect(!slot.isSuspended)
    }

    @Test func everyTokenIsNew() {
        let slot = makeSlot()
        #expect(slot.makeToken() != slot.makeToken())
    }
}
