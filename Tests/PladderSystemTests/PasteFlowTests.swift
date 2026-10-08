import AppKit
import Foundation
import Testing
@testable import PladderSystem

/// `PasteboardOutput` end to end, against a private named pasteboard, a
/// recording key poster and a manual clock. Nothing here types a key or
/// touches the general pasteboard: the developer dictates with a running
/// Pladder while these run.
@Suite struct PasteFlowTests {
    // MARK: Whose clipboard comes back

    @Test func theClipboardComesBackAfterAPaste() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        let result = try await h.output.insert("transcript", submit: false)

        #expect(result == .pasted)
        #expect(h.poster.keys == [PasteHarness.keyV])
        #expect(h.poster.posts.first?.flags == CGEventFlags.maskCommand.rawValue)
        #expect(h.holdsTranscript)
        await h.restoreFallsDue()
        #expect(h.clipboard == "original")
    }

    /// Two pastes inside one restore wait, nothing copied in between: the
    /// second carries the first's snapshot, since capturing then would only
    /// read our own transcript.
    @Test func backToBackPastesRestoreTheOriginalClipboard() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: false)
        try await h.output.insert("second", submit: false)

        await h.restoreFallsDue()
        #expect(h.clipboard == "original")
    }

    /// Nothing reads the first paste, so its restore waits for the cap; the
    /// user copies something, then dictates again inside those eight
    /// seconds. Their new copy is the clipboard now, not the older one.
    @Test func aCopyBetweenTwoPastesIsWhatComesBack() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: false)
        h.userCopies("copied meanwhile")
        try await h.output.insert("second", submit: false)

        await h.restoreFallsDue()
        #expect(h.clipboard == "copied meanwhile")
    }

    /// The same with the key-down snapshot in between, the order the app
    /// runs in.
    @Test func aCopyBeforeTheNextKeyDownIsWhatComesBack() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: false)
        h.userCopies("copied meanwhile")
        await h.output.keeper.prepare()
        try await h.output.insert("second", submit: false)

        await h.restoreFallsDue()
        #expect(h.clipboard == "copied meanwhile")
        // The key-down snapshot was used, not a second read at insert.
        #expect(await h.output.keeper.snapshotsTaken == 2)
    }

    @Test func aNewerPasteTakesOverThePendingRestore() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: false)
        let first = try #require(await h.output.keeper.pendingRestore)
        h.clock.advance(to: .seconds(1))
        try await h.output.insert("second", submit: false)

        // The first restore's timer is cancelled, not merely outrun.
        await first.value
        #expect(!h.clock.deadlines.contains(h.clock.start + .seconds(8)))
        // Past the first paste's cap, short of the second's.
        h.clock.advance(to: .milliseconds(8_500))
        #expect(h.holdsTranscript)
        await h.restoreFallsDue()
        #expect(h.clipboard == "original")
    }

    @Test func aReadMovesTheRestoreDeadline() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        #expect(await h.clock.waitForSleeper(at: .seconds(8)))
        // A busy page reads a second late.
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
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        h.clock.advance(to: .milliseconds(12))
        await h.targetReads()

        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        let restore = await h.output.keeper.pendingRestore
        h.clock.advance(to: .milliseconds(400))
        await restore?.value
        #expect(h.clipboard == "original")
    }

    /// The read as AppKit reports it: an in-process read of the promise on
    /// the main thread, which hops to the keeper on a task of its own.
    @MainActor @Test func aRealReadOfThePromiseIsReported() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        h.clock.advance(to: .milliseconds(30))
        #expect(h.pasteboard.string(forType: .string) == "transcript")

        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        await h.restoreFallsDue()
        #expect(h.clipboard == "original")
    }

    @Test func withoutAccessibilityThePendingRestoreIsDropped() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: false)
        let first = try #require(await h.output.keeper.pendingRestore)
        h.setTrusted(false)
        let result = try await h.output.insert("second", submit: true)

        #expect(result == .copied)
        await first.value
        h.clock.advance(by: .seconds(60))
        #expect(await h.output.keeper.pendingRestore == nil)
        #expect(h.clipboard == "second")
        // No Cmd+V and no Return for the copied one.
        #expect(h.poster.keys == [PasteHarness.keyV])
    }

    @Test func aFailedCmdVPutsTheClipboardBackAtOnce() async {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")
        h.poster.refuse(PasteHarness.keyV)

        await #expect(throws: RecordingKeyPoster.Refused.self) {
            try await h.output.insert("transcript", submit: true)
        }
        #expect(h.clipboard == "original")
        #expect(await h.output.keeper.pendingRestore == nil)
    }

    // MARK: Flush

    @Test func flushRestoresOnceTheTargetHasRead() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        let restore = try #require(await h.output.keeper.pendingRestore)
        h.clock.advance(to: .milliseconds(10))
        await h.targetReads()
        let flush = Task { await h.output.flush() }
        // Not before the floor, as the timer would not: Chromium may read
        // again for the real paste.
        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        #expect(h.holdsTranscript)
        h.clock.advance(to: .milliseconds(400))
        await flush.value

        #expect(h.clipboard == "original")
        // The timer is gone too, so it cannot restore a second time later.
        await restore.value
        #expect(await h.output.keeper.pendingRestore == nil)
    }

    @Test func flushRightAfterCmdVWaitsForTheReadBeforeRestoring() async throws {
        // A dictation pasted on the way out: restoring at once would hand the
        // target app the old clipboard instead of the transcript.
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        let flush = Task { await h.output.flush() }
        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        h.clock.advance(to: .milliseconds(300))
        #expect(h.holdsTranscript)
        await h.targetReads()
        // Read at 300 ms: back 200 ms later, not at the floor.
        #expect(await h.clock.waitForSleeper(at: .milliseconds(500)))
        #expect(h.holdsTranscript)
        h.clock.advance(to: .milliseconds(500))
        await flush.value
        #expect(h.clipboard == "original")
    }

    @Test func flushGivesUpOnATargetThatHasNotReadByTheFloor() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        let flush = Task { await h.output.flush() }
        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        h.clock.advance(to: .milliseconds(400))
        await flush.value
        // Not the eight-second cap: a quit cannot wait that long.
        #expect(h.clipboard == "original")
    }

    @Test func flushLeavesTheUsersNewCopyAlone() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        h.userCopies("copied meanwhile")
        await h.output.flush()

        #expect(h.clipboard == "copied meanwhile")
    }

    @Test func flushWithNothingPendingDoesNothing() async {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")
        let before = h.pasteboard.changeCount

        await h.output.flush()

        #expect(h.pasteboard.changeCount == before)
    }

    // MARK: Prepare

    @Test func prepareTwiceWithNothingChangedReadsTheClipboardOnce() async {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        await h.output.keeper.prepare()
        await h.output.keeper.prepare()
        #expect(await h.output.keeper.snapshotsTaken == 1)

        h.userCopies("copied while speaking")
        await h.output.keeper.prepare()
        #expect(await h.output.keeper.snapshotsTaken == 2)
    }

    /// Key-down and release both prepare, with a copy in between: the paste
    /// reads nothing itself and restores the newer copy.
    @Test func aPrepareAtReleaseKeepsTheCaptureOffThePaste() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")
        await h.output.keeper.prepare()
        h.userCopies("copied while speaking")
        await h.output.keeper.prepare()

        try await h.output.insert("transcript", submit: false)

        #expect(await h.output.keeper.snapshotsTaken == 2)
        await h.restoreFallsDue()
        #expect(h.clipboard == "copied while speaking")
    }

    @Test func aPasteWithoutPrepareStillSnapshots() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)

        #expect(await h.output.keeper.snapshotsTaken == 1)
    }

    // MARK: Return

    @Test func returnWaitsForTheReadPlusTheSubmitDelay() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("send this", submit: true)
        // `insert` has returned and only Cmd+V has gone out.
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
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("send this", submit: true)
        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        h.clock.advance(to: .milliseconds(399))
        #expect(h.poster.keys == [PasteHarness.keyV])

        h.clock.advance(to: .milliseconds(400))
        #expect(await eventually { h.poster.posts.count == 2 })
        #expect(h.poster.posts.last?.key == PasteboardOutput.virtualKeyReturn)
        #expect(h.poster.posts.last?.at == h.clock.start + .milliseconds(400))
        // The clipboard is still waiting for its cap; the Return does not end it.
        #expect(h.holdsTranscript)
    }

    @Test func noReturnWithoutSubmit() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("transcript", submit: false)
        h.clock.advance(to: .milliseconds(100))
        await h.targetReads()
        await h.restoreFallsDue()

        #expect(h.poster.keys == [PasteHarness.keyV])
    }

    @Test func aSendStillWaitingPostsItsReturnBeforeTheNextPaste() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")

        try await h.output.insert("first", submit: true)
        #expect(await h.clock.waitForSleeper(at: .milliseconds(400)))
        h.clock.advance(to: .milliseconds(100))
        try await h.output.insert("second", submit: false)
        // The first send's Return went out ahead of the second Cmd+V, not
        // after it, which would have sent both texts.
        #expect(h.poster.keys == [PasteHarness.keyV, PasteboardOutput.virtualKeyReturn, PasteHarness.keyV])

        // Its own timer, when it fires, posts nothing more.
        h.clock.advance(to: .milliseconds(1_000))
        #expect(await eventually { !h.clock.deadlines.contains(h.clock.start + .milliseconds(400)) })
        for _ in 0..<10 { await Task.yield() }
        #expect(h.poster.keys == [PasteHarness.keyV, PasteboardOutput.virtualKeyReturn, PasteHarness.keyV])
    }

    @Test func aReadBeforeCmdVIsNotThePaste() async throws {
        let h = PasteHarness()
        defer { h.release() }
        h.userCopies("original")
        h.clock.advance(to: .milliseconds(10))

        try await h.output.insert("send this", submit: true)
        #expect(await h.clock.waitForSleeper(at: .milliseconds(410)))
        let promise = try #require(await h.output.keeper.pendingPromise)
        // Stamped before Cmd+V, which went out at 10 ms.
        await h.output.keeper.transcriptRead(promise, at: h.clock.start + .milliseconds(5))

        // Counted, it would have sent Return at 55 ms; the Return waits for
        // the floor instead. A short real wait gives a wrongly counted read
        // the time to post; nothing else is waiting on it.
        h.clock.advance(to: .milliseconds(100))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.poster.keys == [PasteHarness.keyV])
        h.clock.advance(to: .milliseconds(410))
        #expect(await eventually { h.poster.posts.count == 2 })
        #expect(h.poster.posts.last?.at == h.clock.start + .milliseconds(410))
    }

    @Test func aTranscriptTheRestoreCouldNotReplaceIsStillHeld() async throws {
        // Every item of the user's clipboard is over the limit, so the
        // restore leaves the transcript where it is.
        let h = PasteHarness(snapshotLimit: 4)
        defer { h.release() }
        h.userCopies("far too long to keep")

        try await h.output.insert("transcript", submit: false)
        await h.restoreFallsDue()
        #expect(h.holdsTranscript)
        // Its promise is still served, and the next key-down does not read
        // our own transcript back as the user's clipboard.
        #expect(await h.output.keeper.leftPromise != nil)
        let before = await h.output.keeper.snapshotsTaken
        await h.output.prepare()
        #expect(await h.output.keeper.snapshotsTaken == before)

        // The user's next copy ends it.
        h.userCopies("new")
        try await h.output.insert("again", submit: false)
        #expect(await h.output.keeper.leftPromise == nil)
    }
}
