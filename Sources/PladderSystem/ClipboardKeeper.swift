import AppKit
import Foundation
import os

// When the user's clipboard comes back: the Output row of CLAUDE.md's Decisions, and
// docs/ARCHITECTURE.md, "Paste and clipboard". Apps read 0 to 25 ms after Cmd+V, a
// busy web page a second or more.
actor ClipboardKeeper {
    nonisolated let restoreFloor = Duration.milliseconds(400)
    nonisolated let readSettle = Duration.milliseconds(200)
    nonisolated let restoreCap = Duration.seconds(8)

    private let pasteboard: NSPasteboard
    private let clock: PasteClock
    private let snapshotLimit: Int

    private struct Pending {
        // The clipboard before our first paste, carried across back-to-back pastes.
        let snapshot: ClipboardSnapshot
        // What the pasteboard must still be at for the restore to be safe.
        let changeCount: Int
        // Held so the promise outlives the paste, whatever the pasteboard item does.
        let promise: TranscriptPromise
        // Nil while Cmd+V is being posted; a read before then is not the paste.
        var posted: ContinuousClock.Instant?
        var firstRead: ContinuousClock.Instant?
        var lastRead: ContinuousClock.Instant?
        var task: Task<Void, Never>?
    }

    private var pending: Pending?

    // A transcript a restore had to leave, because every item of the user's clipboard
    // was too large to keep: its promise must still be served, and the next snapshot
    // must not read it back as the user's.
    private var leftBehind: (snapshot: ClipboardSnapshot, changeCount: Int, promise: TranscriptPromise)?

    // Reading every representation can take tens of milliseconds, so it happens here,
    // while the user is still speaking.
    private var prepared: (snapshot: ClipboardSnapshot, changeCount: Int)?

    private struct ReadWaiter {
        let promise: TranscriptPromise
        let continuation: CheckedContinuation<ContinuousClock.Instant?, Never>
        let timer: Task<Void, Never>
    }

    private var readWaiters: [Int: ReadWaiter] = [:]
    private var nextReadWaiter = 0
    private(set) var snapshotsTaken = 0

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "paste")

    init(
        pasteboard name: NSPasteboard.Name = .general,
        clock: PasteClock = .continuous,
        snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes
    ) {
        // By name: `NSPasteboard` is not `Sendable`, and this one never leaves the actor.
        pasteboard = NSPasteboard(name: name)
        self.clock = clock
        self.snapshotLimit = snapshotLimit
    }

    struct Paste: Sendable {
        let promise: TranscriptPromise
        let posted: ContinuousClock.Instant
    }

    // MARK: Before the paste

    func prepare() {
        let now = pasteboard.changeCount
        // While our transcript is still on the pasteboard, the user's clipboard is the
        // pending snapshot. Capturing would only read our own promise, off the main thread.
        if pending?.changeCount == now || leftBehind?.changeCount == now {
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

    // Also ends any restore still pending: this paste takes it over.
    private func clipboardToRestore() -> ClipboardSnapshot {
        let prep = prepared
        prepared = nil
        let now = pasteboard.changeCount
        let leftOver = leftBehind
        leftBehind = nil
        if let leftOver, leftOver.changeCount == now { return leftOver.snapshot }
        if let carried = pending {
            endPending()
            // Our previous transcript is still on the pasteboard, so the user's clipboard is
            // the one that paste saved. If anything was written since, the user copied it.
            if carried.changeCount == now { return carried.snapshot }
        }
        if let prep, prep.changeCount == now {
            return prep.snapshot
        }
        return takeSnapshot()
    }

    // MARK: The paste

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
            // The same restore as after a paste: a transcript the snapshot cannot replace is
            // kept in `leftBehind`, so the next `prepare()` does not take it for the user's clipboard.
            if let failed = pending, failed.changeCount == ourChangeCount {
                endPending()
                restore(failed)
            }
            throw error
        }
        let posted = clock.now()
        pending?.posted = posted
        scheduleRestore()
        return Paste(promise: promise, posted: posted)
    }

    // A restore still pending would put the old clipboard back over the transcript.
    func copy(_ text: String) {
        endPending()
        prepared = nil
        leftBehind = nil
        _ = ClipboardSnapshot.write(text, to: pasteboard)
    }

    // Safe is not "now": the target app reads some time after Cmd+V. Waits as the timer
    // would, but gives up on an app that has not read by the floor, since a quit cannot
    // wait out the cap: at most `restoreFloor` plus `readSettle`.
    func flush() async {
        guard let current = pending else { return }
        guard pasteboard.changeCount == current.changeCount else {
            endPending()
            return
        }
        if let posted = current.posted {
            let floor = posted + restoreFloor
            if current.firstRead == nil { _ = await firstRead(of: current.promise, by: floor) }
            // The timer, or a newer paste, may have got there while this waited.
            guard let latest = pending, latest.promise === current.promise else { return }
            let due = latest.lastRead.map { min(max(floor, $0 + readSettle), floor + readSettle) } ?? floor
            if due > clock.now() { try? await clock.sleep(due) }
        }
        guard let latest = pending, latest.promise === current.promise else { return }
        endPending()
        restore(latest)
    }

    // MARK: After the paste

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

    private func scheduleRestore() {
        guard let current = pending, let posted = current.posted else { return }
        current.task?.cancel()
        let due = Self.restoreDue(
            posted: posted, lastRead: current.lastRead, floor: restoreFloor, settle: readSettle, cap: restoreCap)
        pending?.task = restoreTask(for: current.promise, at: due)
    }

    // AppKit serves promises on the main thread; this arrives from there by a task.
    func transcriptRead(_ promise: TranscriptPromise, at instant: ContinuousClock.Instant) {
        // The actor finishes `paste` before this runs, so `posted` is set either way; only
        // the instant tells a read before Cmd+V, which is not the paste, from the paste.
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

    // Detached, so the caller's cancellation cannot make the restore fire early and give
    // the target app the user's old clipboard.
    private func restoreTask(for promise: TranscriptPromise, at due: ContinuousClock.Instant) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [clock] in
            // A read that moves the deadline, or a newer paste, which takes over the snapshot,
            // cancels this.
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

    private func restore(_ done: Pending) {
        done.snapshot.restore(ifChangeCountIs: done.changeCount, on: pasteboard)
        if pasteboard.changeCount == done.changeCount {
            leftBehind = (done.snapshot, done.changeCount, done.promise)
        }
    }

    private func endPending() {
        guard let current = pending else { return }
        current.task?.cancel()
        pending = nil
        resolveReadWaiters(for: current.promise, with: nil)
    }

    // MARK: Waiting for the read

    func firstRead(of promise: TranscriptPromise, by deadline: ContinuousClock.Instant) async -> ContinuousClock.Instant? {
        guard let current = pending, current.promise === promise else { return nil }
        if let read = current.firstRead { return read }
        let id = nextReadWaiter
        nextReadWaiter += 1
        let timer = Task.detached(priority: .utility) { [clock] in
            guard (try? await clock.sleep(deadline)) != nil else { return }
            await self.resolveReadWaiter(id, with: nil)
        }
        // The actor is held until the continuation is stored, so the timer, however short,
        // finds the waiter there.
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
    var leftBehindPromise: TranscriptPromise? { leftBehind?.promise }
}

struct PasteClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (_ deadline: ContinuousClock.Instant) async throws -> Void

    static let continuous = PasteClock(
        now: { .now },
        sleep: { try await Task.sleep(until: $0, clock: .continuous) })
}
