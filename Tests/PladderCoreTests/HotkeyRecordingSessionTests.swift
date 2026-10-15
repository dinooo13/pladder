import Foundation
import Testing
@testable import PladderCore

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
