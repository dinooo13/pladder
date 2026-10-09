import AppKit
import Foundation
import os

/// Owns the user's clipboard across a paste: the snapshot taken before it,
/// the transcript published as a promise, and when the snapshot goes back.
///
/// The restore waits for the paste as well as for a clock. The transcript goes
/// on the pasteboard as a promise, so the target app's read comes back to us as
/// a call to `TranscriptPromise`. The old clipboard returns `restoreFloor` after
/// Cmd+V, as it always has, if the transcript has been read by then, and
/// otherwise `readSettle` after the read. An app that is busy when Cmd+V
/// arrives reads late, and the fixed delay alone handed it the user's old
/// clipboard instead of the transcript. If nothing reads it, `restoreCap` ends
/// the wait, which leaves the transcript on the clipboard a little longer and
/// never pastes stale text. Issue #40 has the measurements.
///
/// An actor because the pending restore is shared mutable state: a second
/// paste may start while the previous restore is still waiting. The restore
/// itself runs on a detached task, so the caller being cancelled — a cancelled
/// dictation — can never yank the pasteboard out from under an app that has
/// not read it yet.
///
/// The pasteboard and the clock are parameters, so the tests run every path
/// against a private named pasteboard and a manual clock.
actor ClipboardKeeper {
    /// The earliest the previous clipboard comes back after Cmd+V, read or not.
    ///
    /// The paste is asynchronous from our point of view: the target app reads the
    /// pasteboard on its own run loop some time after it receives the key event,
    /// 0 to 25 ms later for every app measured, a second or more for a web page
    /// whose main thread is busy. Restoring before the read gives the app the
    /// *old* contents.
    ///
    /// A read is not always the paste: Chromium sometimes reads once as Cmd+V
    /// arrives and again when the page gets round to pasting, and the
    /// pasteboard keeps the data after the first read, so the second never
    /// reaches us. Nothing says which read is which, so a read never brings
    /// the clipboard back sooner than this. 400 ms is the fixed delay this
    /// replaced, which is enough for every app that is not busy.
    nonisolated let restoreFloor = Duration.milliseconds(400)

    /// How long after the target app's last read the previous clipboard comes
    /// back, when that is later than `restoreFloor`: a busy app that read late.
    nonisolated let readSettle = Duration.milliseconds(200)

    /// How long after Cmd+V the previous clipboard comes back when nothing has
    /// read the transcript: a paste into something that takes no text, or an
    /// app that never got the key event. The transcript stays on the clipboard
    /// until then, which is the safe way to be wrong.
    nonisolated let restoreCap = Duration.seconds(8)

    private let pasteboard: NSPasteboard
    private let clock: PasteClock
    /// The largest item a snapshot keeps; the tests make it small.
    private let snapshotLimit: Int

    /// A restore that has been scheduled but has not run yet.
    private struct Pending {
        /// The user's clipboard, as it was before *our first* uninterrupted
        /// paste. Carried forward across back-to-back pastes.
        let snapshot: ClipboardSnapshot
        /// The change count our write produced, i.e. what the pasteboard must
        /// still be at for the restore to be safe.
        let changeCount: Int
        /// The transcript on the pasteboard, which reports every read. Held
        /// here so it outlives the paste whatever the pasteboard item does.
        let promise: TranscriptPromise
        /// When Cmd+V was posted. Nil while it is still being posted; a read
        /// before then is not the paste and does not count.
        var posted: ContinuousClock.Instant?
        /// The first and the last read of the transcript since Cmd+V.
        var firstRead: ContinuousClock.Instant?
        var lastRead: ContinuousClock.Instant?
        /// The detached task waiting for the restore to fall due. Nil while
        /// the paste is still being posted.
        var task: Task<Void, Never>?
    }

    private var pending: Pending?

    /// A transcript a restore had to leave on the pasteboard, because every
    /// item of the user's clipboard was too large to keep. Held so its promise
    /// can still be served, and so the next snapshot does not read our own
    /// text back as the user's: until the user copies something, the
    /// clipboard is still this, and its snapshot is the one that restores
    /// nothing.
    private var left: (snapshot: ClipboardSnapshot, changeCount: Int, promise: TranscriptPromise)?

    /// The clipboard as it was when `prepare()` last looked, ready for
    /// `paste` to carry forward. Nil when already used. Reading every
    /// representation can take tens of milliseconds, so `prepare()` does it
    /// while the user is still speaking instead of on the release-to-paste
    /// path.
    private var prepared: (snapshot: ClipboardSnapshot, changeCount: Int)?

    /// Someone waiting in `firstRead(of:by:)`, and the timer that ends the
    /// wait at its deadline.
    private struct ReadWaiter {
        let promise: TranscriptPromise
        let continuation: CheckedContinuation<ContinuousClock.Instant?, Never>
        let timer: Task<Void, Never>
    }

    private var readWaiters: [Int: ReadWaiter] = [:]
    private var nextReadWaiter = 0

    /// How many snapshots have been read off the pasteboard. The tests count
    /// these to see that a repeated `prepare()` reads nothing.
    private(set) var snapshotsTaken = 0

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "paste")

    init(
        pasteboard name: NSPasteboard.Name = .general,
        clock: PasteClock = .continuous,
        snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes
    ) {
        // By name rather than the object: `NSPasteboard` is not `Sendable`,
        // and the one made here never leaves the actor.
        pasteboard = NSPasteboard(name: name)
        self.clock = clock
        self.snapshotLimit = snapshotLimit
    }

    /// What `paste` hands back: enough to wait for the transcript's read.
    struct Paste: Sendable {
        let promise: TranscriptPromise
        /// When Cmd+V was posted.
        let posted: ContinuousClock.Instant
    }

    // MARK: Before the paste

    /// Snapshots the clipboard while the user is still speaking. Cheap when
    /// called again with nothing changed: the snapshot already taken is kept,
    /// so a caller may call this at key-down and again at release.
    func prepare() {
        let now = pasteboard.changeCount
        // While our own transcript is still on the pasteboard the user's
        // clipboard is the pending snapshot, which `paste` carries forward.
        // Capturing would only read our own promise, from off the main
        // thread, which AppKit warns against.
        if let pending, pending.changeCount == now {
            prepared = nil
            return
        }
        if let left, left.changeCount == now {
            prepared = nil
            return
        }
        if let prepared, prepared.changeCount == now { return }
        prepared = (takeSnapshot(), now)
    }

    private func takeSnapshot() -> ClipboardSnapshot {
        snapshotsTaken += 1
        return ClipboardSnapshot.capture(from: pasteboard, maximumItemBytes: snapshotLimit)
    }

    /// The user's clipboard to put back after the paste about to happen, and
    /// the end of any restore still pending, which this paste takes over.
    private func clipboardToRestore() -> ClipboardSnapshot {
        let prep = prepared
        prepared = nil
        let now = pasteboard.changeCount
        let leftOver = left
        left = nil
        if let leftOver, leftOver.changeCount == now { return leftOver.snapshot }
        if let carried = pending {
            endPending()
            // Our previous transcript is still on the pasteboard: the user's
            // clipboard is the one that paste saved, and snapshotting now
            // would capture our own text. If anything was written since, the
            // user copied it, and that copy is their clipboard now; carrying
            // the old snapshot would put the older one back over it.
            if carried.changeCount == now { return carried.snapshot }
        }
        // The snapshot from `prepare()` is only valid if nobody touched the
        // pasteboard in between; anything the user copied since wins.
        if let prep, prep.changeCount == now {
            return prep.snapshot
        }
        return takeSnapshot()
    }

    // MARK: The paste

    /// Publishes `text` as a promise, calls `post` to send Cmd+V, and
    /// schedules the restore. Returns as soon as `post` has returned; the
    /// restore runs on a detached task afterwards. If `post` throws, the
    /// clipboard is put back at once and the error rethrown.
    func paste(_ text: String, post: @Sendable () throws -> Void) throws -> Paste {
        let snapshot = clipboardToRestore()

        let promise = TranscriptPromise(text, now: clock.now) { [weak self] promise, instant in
            Task { await self?.transcriptRead(promise, at: instant) }
        }
        let ourChangeCount = ClipboardSnapshot.publish(promise, to: pasteboard)
        pending = Pending(snapshot: snapshot, changeCount: ourChangeCount, promise: promise)

        do {
            try post()
        } catch {
            // Never leave the user's clipboard holding our transcript.
            if pending?.changeCount == ourChangeCount { endPending() }
            snapshot.restore(ifChangeCountIs: ourChangeCount, on: pasteboard)
            throw error
        }
        let posted = clock.now()
        pending?.posted = posted
        scheduleRestore()
        return Paste(promise: promise, posted: posted)
    }

    /// The clipboard-only path: `text` replaces the clipboard and stays, and
    /// nothing is restored. A restore still pending from an earlier paste
    /// would put the old clipboard back over the transcript, so it is dropped.
    func copy(_ text: String) {
        endPending()
        prepared = nil
        left = nil
        _ = ClipboardSnapshot.write(text, to: pasteboard)
    }

    /// Puts the user's clipboard back as soon as that is safe instead of on
    /// the timer, if our transcript is still on it. For quitting: a restore
    /// pending on a detached task would die with the process.
    ///
    /// Safe is not "now". A dictation can be pasted on the way out, and the
    /// target app reads the transcript some time after Cmd+V; restoring
    /// before that hands it the user's old clipboard instead. So this waits
    /// as the timer would — for the read, and `readSettle` after it, no
    /// sooner than `restoreFloor` after Cmd+V — except that it gives up on
    /// an app that has not read by the floor, since a quit cannot wait out
    /// the cap. At most `restoreFloor` plus `readSettle`.
    func flush() async {
        guard let current = pending else { return }
        // The user copied something since: theirs stays, so there is nothing
        // to put back and nothing to wait for.
        guard pasteboard.changeCount == current.changeCount else {
            endPending()
            return
        }
        if let posted = current.posted {
            let floor = posted + restoreFloor
            if current.firstRead == nil { _ = await firstRead(of: current.promise, by: floor) }
            // The timer, or a newer paste, may have got there while this
            // waited.
            guard let latest = pending, latest.promise === current.promise else { return }
            let due = latest.lastRead.map { min(max(floor, $0 + readSettle), floor + readSettle) } ?? floor
            if due > clock.now() { try? await clock.sleep(due) }
        }
        guard let latest = pending, latest.promise === current.promise else { return }
        endPending()
        restore(latest)
    }

    // MARK: After the paste

    /// When the pending restore falls due: `settle` after the last read since
    /// Cmd+V but no sooner than `floor` after Cmd+V, or `cap` after Cmd+V if
    /// nothing has read it, and never later than that.
    static func restoreDue(
        posted: ContinuousClock.Instant,
        lastRead: ContinuousClock.Instant?,
        floor: Duration,
        settle: Duration,
        cap: Duration
    ) -> ContinuousClock.Instant {
        let latest = posted + cap
        guard let lastRead else { return latest }
        return min(max(posted + floor, lastRead + settle), latest)
    }

    /// (Re)starts the pending restore's wait from what is known now.
    private func scheduleRestore() {
        guard let current = pending, let posted = current.posted else { return }
        current.task?.cancel()
        let due = Self.restoreDue(
            posted: posted, lastRead: current.lastRead, floor: restoreFloor, settle: readSettle, cap: restoreCap)
        pending?.task = restoreTask(for: current.promise, at: due)
    }

    /// The target app read the transcript. Called from the main thread, where
    /// AppKit serves promises, by way of a task.
    func transcriptRead(_ promise: TranscriptPromise, at instant: ContinuousClock.Instant) {
        // A read before Cmd+V was posted is not the paste: the actor finishes
        // `paste` before this runs, so `posted` is set by now either way, and
        // only the instant tells them apart.
        guard let current = pending, current.promise === promise, let posted = current.posted,
              instant >= posted else { return }
        if current.firstRead == nil {
            let seconds = (instant - posted).timeInterval
            Self.log.notice("clipboard read \(seconds, format: .fixed(precision: 3)) s after Cmd+V")
            pending?.firstRead = instant
            resolveReadWaiters(for: promise, with: instant)
        }
        pending?.lastRead = instant
        scheduleRestore()
    }

    /// Waits off the critical path for the restore to fall due, then hands
    /// back to the actor to do it. Detached so the caller's cancellation
    /// cannot make the restore fire early, which would give the target app
    /// the user's old clipboard instead of the transcript.
    private func restoreTask(for promise: TranscriptPromise, at due: ContinuousClock.Instant) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [clock] in
            // A read that moves the deadline, or a *newer* paste, cancels this
            // task; the newer paste takes ownership of the snapshot, so there
            // is nothing left to restore.
            guard (try? await clock.sleep(due)) != nil, !Task.isCancelled else { return }
            await self.completeRestore(promise)
        }
    }

    private func completeRestore(_ promise: TranscriptPromise) {
        guard let pending, pending.promise === promise else { return }
        endPending()
        if pending.lastRead == nil {
            Self.log.notice("clipboard not read within \(self.restoreCap.components.seconds) s of Cmd+V; restoring")
        }
        restore(pending)
    }

    /// Puts the snapshot back, and keeps the transcript's promise alive when
    /// the snapshot could not replace it.
    private func restore(_ done: Pending) {
        done.snapshot.restore(ifChangeCountIs: done.changeCount, on: pasteboard)
        if pasteboard.changeCount == done.changeCount {
            left = (done.snapshot, done.changeCount, done.promise)
        }
    }

    /// Ends the pending restore without restoring: its timer stops and anyone
    /// waiting for its read is let go.
    private func endPending() {
        guard let current = pending else { return }
        current.task?.cancel()
        pending = nil
        resolveReadWaiters(for: current.promise, with: nil)
    }

    // MARK: Waiting for the read

    /// The instant the target app first read `promise` after Cmd+V. Nil at
    /// `deadline` if nothing has, or as soon as the paste is no longer
    /// pending: restored, taken over by a newer paste, or dropped.
    func firstRead(of promise: TranscriptPromise, by deadline: ContinuousClock.Instant) async -> ContinuousClock.Instant? {
        guard let current = pending, current.promise === promise else { return nil }
        if let read = current.firstRead { return read }
        let id = nextReadWaiter
        nextReadWaiter += 1
        let timer = Task.detached(priority: .utility) { [clock] in
            guard (try? await clock.sleep(deadline)) != nil else { return }
            await self.resolveReadWaiter(id, with: nil)
        }
        // The actor is held until the continuation is stored, so the timer,
        // however short, finds the waiter there.
        return await withCheckedContinuation { continuation in
            readWaiters[id] = ReadWaiter(promise: promise, continuation: continuation, timer: timer)
        }
    }

    private func resolveReadWaiter(_ id: Int, with instant: ContinuousClock.Instant?) {
        guard let waiter = readWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: instant)
    }

    private func resolveReadWaiters(for promise: TranscriptPromise, with instant: ContinuousClock.Instant?) {
        for (id, waiter) in readWaiters where waiter.promise === promise {
            resolveReadWaiter(id, with: instant)
        }
    }

    // MARK: For the tests

    var pendingRestore: Task<Void, Never>? { pending?.task }
    var pendingPromise: TranscriptPromise? { pending?.promise }
    var leftPromise: TranscriptPromise? { left?.promise }
}

/// The time the paste waits on: the continuous clock in the app, a manual
/// one in the tests, which is what keeps the restore and Return tests to
/// milliseconds instead of the eight seconds the cap would take.
struct PasteClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    /// Returns at `deadline`, or throws when the waiting task is cancelled.
    let sleep: @Sendable (_ deadline: ContinuousClock.Instant) async throws -> Void

    static let continuous = PasteClock(
        now: { .now },
        sleep: { try await Task.sleep(until: $0, clock: .continuous) })
}
