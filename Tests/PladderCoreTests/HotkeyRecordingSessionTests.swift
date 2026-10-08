import Foundation
import Testing
@testable import PladderCore

/// One chord recorder at a time, and the hotkey back only when none records.
@Suite struct HotkeyRecordingSessionTests {
    typealias Session = HotkeyRecordingSession<String>

    @Test func theFirstRecorderSuspends() {
        var s = Session()
        #expect(!s.isSuspended)
        #expect(s.begin("A") == .init(suspends: true))
        #expect(s.isSuspended)
        #expect(s.recorder == "A")
    }

    @Test func aSecondRecorderEndsTheFirstAndStaysSuspended() {
        var s = Session()
        _ = s.begin("A")
        #expect(s.begin("B") == .init(displaced: "A", suspends: false))
        #expect(s.isSuspended)
        // The displaced recorder's own end, which its cancel triggers, is
        // not the one that resumes.
        #expect(s.end("A") == false)
        #expect(s.isSuspended)
        #expect(s.end("B") == true)
        #expect(!s.isSuspended)
    }

    @Test func endingTwiceResumesOnce() {
        var s = Session()
        _ = s.begin("A")
        #expect(s.end("A") == true)
        #expect(s.end("A") == false)
        #expect(!s.isSuspended)
    }

    @Test func anEndWithNothingRecordingIsANoOp() {
        // A field that disappears cancels its recorder whether or not it was
        // recording.
        var s = Session()
        #expect(s.end("A") == false)
        #expect(!s.isSuspended)
    }

    @Test func beginningAgainChangesNothing() {
        var s = Session()
        _ = s.begin("A")
        #expect(s.begin("A") == .init(suspends: false))
        #expect(s.end("A") == true)
    }

    @Test func aFreshSessionAfterTheLastEndSuspendsAgain() {
        var s = Session()
        _ = s.begin("A")
        _ = s.begin("B")
        _ = s.end("B")
        #expect(s.begin("A") == .init(suspends: true))
    }
}
