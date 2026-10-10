import AppKit
import Foundation
import PladderTestSupport
import Testing
@testable import PladderSystem

// Never the general pasteboard, never a real key: the developer dictates with a
// running Pladder while these run.

extension PasteboardTests {
    @Suite(.timeLimit(.minutes(1))) struct PasteFlowTests {
        @Test func theClipboardComesBackAfterAPaste() async throws {
            let h = PasteHarness(clipboard: "original")

            let result = try await h.output.insert("transcript", submit: false)

            #expect(result == .pasted)
            #expect(h.poster.keys == [PasteHarness.keyV])
            #expect(h.poster.posts.first?.flags == CGEventFlags.maskCommand.rawValue)
            #expect(h.holdsTranscript)
            await h.restoreFallsDue()
            #expect(h.clipboard == "original")
        }

        @Test func backToBackPastesRestoreTheOriginalClipboard() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: false)
            try await h.output.insert("second", submit: false)

            await h.restoreFallsDue()
            #expect(h.clipboard == "original")
        }

        @Test func aCopyBetweenTwoPastesIsWhatComesBack() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: false)
            h.userCopies("copied meanwhile")
            try await h.output.insert("second", submit: false)

            await h.restoreFallsDue()
            #expect(h.clipboard == "copied meanwhile")
        }

        @Test func aCopyBeforeTheNextKeyDownIsWhatComesBack() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: false)
            h.userCopies("copied meanwhile")
            await h.output.keeper.prepare()
            try await h.output.insert("second", submit: false)

            await h.restoreFallsDue()
            #expect(h.clipboard == "copied meanwhile")
            #expect(await h.output.keeper.snapshotsTaken == 2)
        }

        @Test func aNewerPasteTakesOverThePendingRestore() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: false)
            let first = try #require(await h.output.keeper.pendingRestore)
            h.clock.advance(to: .seconds(1))
            try await h.output.insert("second", submit: false)

            await first.value
            #expect(!h.clock.deadlines.contains(h.clock.start + .seconds(8)))
            h.clock.advance(to: .milliseconds(8_500))
            #expect(h.holdsTranscript)
            await h.restoreFallsDue()
            #expect(h.clipboard == "original")
        }

        @Test func aReadMovesTheRestoreDeadline() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            #expect(await h.clock.waitForSleeper(at: .seconds(8)))
            h.clock.advance(to: .seconds(1))
            await h.targetReads()

            #expect(await h.clock.waitForSleeper(at: .milliseconds(1_200)))
            #expect(!h.clock.deadlines.contains(h.clock.start + .seconds(8)))
            let restore = await h.output.keeper.pendingRestore
            h.clock.advance(to: .milliseconds(1_199))
            #expect(h.holdsTranscript)
            h.clock.advance(to: .milliseconds(1_200))
            await restore?.value
            #expect(h.clipboard == "original")
        }

        @Test func aPromptReadRestoresAtTheFloor() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            h.clock.advance(to: .milliseconds(12))
            await h.targetReads()

            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            let restore = await h.output.keeper.pendingRestore
            h.clock.advance(to: .milliseconds(400))
            await restore?.value
            #expect(h.clipboard == "original")
        }

        @MainActor @Test func aRealReadOfThePromiseIsReported() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            h.clock.advance(to: .milliseconds(30))
            #expect(h.pasteboard.string(forType: .string) == "transcript")

            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            await h.restoreFallsDue()
            #expect(h.clipboard == "original")
        }

        @Test func withoutAccessibilityThePendingRestoreIsDropped() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: false)
            let first = try #require(await h.output.keeper.pendingRestore)
            h.setTrusted(false)
            let result = try await h.output.insert("second", submit: true)

            #expect(result == .copied)
            await first.value
            h.clock.advance(by: .seconds(60))
            #expect(await h.output.keeper.pendingRestore == nil)
            #expect(h.clipboard == "second")
            #expect(h.poster.keys == [PasteHarness.keyV])
        }

        @Test func aFailedCmdVPutsTheClipboardBackAtOnce() async {
            let h = PasteHarness(clipboard: "original")
            h.poster.refuse(PasteHarness.keyV)

            await #expect(throws: RecordingKeyPoster.Refused.self) {
                try await h.output.insert("transcript", submit: true)
            }
            #expect(h.clipboard == "original")
            #expect(await h.output.keeper.pendingRestore == nil)
        }

        @Test func aFailedCmdVThatCannotRestoreStillHoldsTheTranscript() async throws {
            let h = PasteHarness(snapshotLimit: 4)
            h.userCopies("far too long to keep")
            h.poster.refuse(PasteHarness.keyV)

            await #expect(throws: RecordingKeyPoster.Refused.self) {
                try await h.output.insert("transcript", submit: false)
            }
            #expect(h.holdsTranscript)
            #expect(await h.output.keeper.pendingRestore == nil)
            #expect(await h.output.keeper.leftPromise != nil)
            let before = await h.output.keeper.snapshotsTaken
            await h.output.prepare()
            #expect(await h.output.keeper.snapshotsTaken == before)
        }

        @Test func flushRestoresOnceTheTargetHasRead() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            let restore = try #require(await h.output.keeper.pendingRestore)
            h.clock.advance(to: .milliseconds(10))
            await h.targetReads()
            let flush = Task { await h.output.flush() }
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            #expect(h.holdsTranscript)
            h.clock.advance(to: .milliseconds(400))
            await flush.value

            #expect(h.clipboard == "original")
            await restore.value
            #expect(await h.output.keeper.pendingRestore == nil)
        }

        @Test func flushRightAfterCmdVWaitsForTheReadBeforeRestoring() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            let flush = Task { await h.output.flush() }
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            h.clock.advance(to: .milliseconds(300))
            #expect(h.holdsTranscript)
            await h.targetReads()
            #expect(await h.clock.waitForSleeper(at: .milliseconds(500)))
            #expect(h.holdsTranscript)
            h.clock.advance(to: .milliseconds(500))
            await flush.value
            #expect(h.clipboard == "original")
        }

        @Test func flushGivesUpOnATargetThatHasNotReadByTheFloor() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            let flush = Task { await h.output.flush() }
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            h.clock.advance(to: .milliseconds(400))
            await flush.value
            #expect(h.clipboard == "original")
        }

        @Test func flushLeavesTheUsersNewCopyAlone() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            h.userCopies("copied meanwhile")
            await h.output.flush()

            #expect(h.clipboard == "copied meanwhile")
        }

        @Test func flushWithNothingPendingDoesNothing() async {
            let h = PasteHarness(clipboard: "original")
            let before = h.pasteboard.changeCount

            await h.output.flush()

            #expect(h.pasteboard.changeCount == before)
        }

        @Test func prepareTwiceWithNothingChangedReadsTheClipboardOnce() async {
            let h = PasteHarness(clipboard: "original")

            await h.output.keeper.prepare()
            await h.output.keeper.prepare()
            #expect(await h.output.keeper.snapshotsTaken == 1)

            h.userCopies("copied while speaking")
            await h.output.keeper.prepare()
            #expect(await h.output.keeper.snapshotsTaken == 2)
        }

        @Test func aPrepareAtReleaseKeepsTheCaptureOffThePaste() async throws {
            let h = PasteHarness(clipboard: "original")
            await h.output.keeper.prepare()
            h.userCopies("copied while speaking")
            await h.output.keeper.prepare()

            try await h.output.insert("transcript", submit: false)

            #expect(await h.output.keeper.snapshotsTaken == 2)
            await h.restoreFallsDue()
            #expect(h.clipboard == "copied while speaking")
        }

        @Test func aPasteWithoutPrepareStillSnapshots() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)

            #expect(await h.output.keeper.snapshotsTaken == 1)
        }

        @Test func returnWaitsForTheReadPlusTheSubmitDelay() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("send this", submit: true)
            #expect(h.poster.keys == [PasteHarness.keyV])
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))

            h.clock.advance(to: .milliseconds(100))
            await h.targetReads()
            #expect(await h.clock.waitForSleeper(at: .milliseconds(150)))
            #expect(h.poster.keys == [PasteHarness.keyV])

            h.clock.advance(to: .milliseconds(150))
            #expect(await eventually { h.poster.posts.count == 2 })
            let posted = h.poster.posts.last
            #expect(posted?.key == PasteboardOutput.virtualKeyReturn)
            #expect(posted?.flags == 0)
            #expect(posted?.at == h.clock.start + .milliseconds(150))
        }

        @Test func returnWithoutAReadComesAtTheFloor() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("send this", submit: true)
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            h.clock.advance(to: .milliseconds(399))
            #expect(h.poster.keys == [PasteHarness.keyV])

            h.clock.advance(to: .milliseconds(400))
            #expect(await eventually { h.poster.posts.count == 2 })
            #expect(h.poster.posts.last?.key == PasteboardOutput.virtualKeyReturn)
            #expect(h.poster.posts.last?.at == h.clock.start + .milliseconds(400))
            #expect(h.holdsTranscript)
        }

        @Test func noReturnWithoutSubmit() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("transcript", submit: false)
            h.clock.advance(to: .milliseconds(100))
            await h.targetReads()
            await h.restoreFallsDue()

            #expect(h.poster.keys == [PasteHarness.keyV])
        }

        @Test func aSendStillWaitingPostsItsReturnBeforeTheNextPaste() async throws {
            let h = PasteHarness(clipboard: "original")

            try await h.output.insert("first", submit: true)
            #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
            h.clock.advance(to: .milliseconds(100))
            try await h.output.insert("second", submit: false)
            #expect(h.poster.keys == [PasteHarness.keyV, PasteboardOutput.virtualKeyReturn, PasteHarness.keyV])

            h.clock.advance(to: .milliseconds(1_000))
            #expect(await eventually { !h.clock.deadlines.contains(h.clock.start + .milliseconds(400)) })
            for _ in 0..<10 { await Task.yield() }
            #expect(h.poster.keys == [PasteHarness.keyV, PasteboardOutput.virtualKeyReturn, PasteHarness.keyV])
        }

        @Test func aReadBeforeCmdVIsNotThePaste() async throws {
            let h = PasteHarness(clipboard: "original")
            h.clock.advance(to: .milliseconds(10))

            try await h.output.insert("send this", submit: true)
            #expect(await h.clock.waitForSleeper(at: .milliseconds(410)))
            let promise = try #require(await h.output.keeper.pendingPromise)
            await h.output.keeper.transcriptRead(promise, at: h.clock.start + .milliseconds(5))

            // A short real wait gives a wrongly counted read the time to post its Return.
            h.clock.advance(to: .milliseconds(100))
            try? await Task.sleep(for: .milliseconds(20))
            #expect(h.poster.keys == [PasteHarness.keyV])
            h.clock.advance(to: .milliseconds(410))
            #expect(await eventually { h.poster.posts.count == 2 })
            #expect(h.poster.posts.last?.at == h.clock.start + .milliseconds(410))
        }

        @Test func aTranscriptTheRestoreCouldNotReplaceIsStillHeld() async throws {
            let h = PasteHarness(snapshotLimit: 4)
            h.userCopies("far too long to keep")

            try await h.output.insert("transcript", submit: false)
            await h.restoreFallsDue()
            #expect(h.holdsTranscript)
            #expect(await h.output.keeper.leftBehindPromise != nil)
            let before = await h.output.keeper.snapshotsTaken
            await h.output.prepare()
            #expect(await h.output.keeper.snapshotsTaken == before)

            h.userCopies("new")
            try await h.output.insert("again", submit: false)
            #expect(await h.output.keeper.leftBehindPromise == nil)
        }
    }
}
