import AppKit
import Foundation
import Synchronization
@testable import PladderSystem

/// A clock that moves only when the test says so. Every restore and Return
/// deadline in `PasteboardOutput` is a sleep on this, so an eight-second cap
/// passes in a microsecond and nothing depends on the machine's load.
final class ManualClock: Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they got as far as waiting.
        var cancelled: Set<Int> = []
    }

    private let state: Mutex<State>
    let start: ContinuousClock.Instant

    init() {
        let start = ContinuousClock.now
        self.start = start
        state = Mutex(State(now: start))
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }

    /// Deadlines somebody is asleep until right now.
    var deadlines: [ContinuousClock.Instant] { state.withLock { $0.sleepers.map(\.deadline) } }

    var pasteClock: PasteClock {
        PasteClock(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }

    /// Moves time on and wakes everyone whose deadline it reached.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let now = state.now
            let woken = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return woken
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Advances to `start + offset`.
    func advance(to offset: Duration) {
        advance(by: start + offset - now)
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early = state.withLock { state -> Result<Void, any Error>? in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits, in real time but briefly, until somebody sleeps until
    /// `start + offset`: a detached task has reached its wait.
    func waitForSleeper(at offset: Duration) async -> Bool {
        let deadline = start + offset
        return await eventually { self.deadlines.contains(deadline) }
    }
}

/// Polls `condition` for up to about two seconds of real time, a millisecond
/// at a time, for what a detached task does on its own schedule.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Records every key instead of typing it, stamped with the manual clock.
final class RecordingKeyPoster: KeyPoster {
    struct Post: Equatable {
        let key: CGKeyCode
        let flags: UInt64
        let at: ContinuousClock.Instant
    }

    struct Refused: Error {}

    private let clock: ManualClock
    private let state = Mutex<(posts: [Post], refusing: Set<CGKeyCode>)>(([], []))

    init(clock: ManualClock) { self.clock = clock }

    var posts: [Post] { state.withLock { $0.posts } }
    var keys: [CGKeyCode] { posts.map(\.key) }

    /// Every later post of `key` throws, as a failed event creation would.
    func refuse(_ key: CGKeyCode) { state.withLock { _ = $0.refusing.insert(key) } }

    func post(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let at = clock.now
        try state.withLock { state in
            guard !state.refusing.contains(key) else { throw Refused() }
            state.posts.append(Post(key: key, flags: flags.rawValue, at: at))
        }
    }
}

/// One `PasteboardOutput` wired to a private named pasteboard, a recording
/// poster, a manual clock and a switchable grant. Never `.general`: the
/// developer dictates with a running Pladder while these run.
struct PasteHarness {
    static let keyV: CGKeyCode = 0x09
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let name = NSPasteboard.Name("de.dinooo13.pladder.tests.\(UUID().uuidString)")
    let clock = ManualClock()
    let poster: RecordingKeyPoster
    let output: PasteboardOutput

    init(submitDelay: Duration = .milliseconds(50), snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes) {
        let poster = RecordingKeyPoster(clock: clock)
        self.poster = poster
        let grant = Grant()
        self.grant = grant
        output = PasteboardOutput(
            submitDelay: submitDelay, pasteboard: name, poster: poster,
            isTrusted: { grant.value }, clock: clock.pasteClock, snapshotLimit: snapshotLimit)
    }

    /// The grant, shared with the output's `isTrusted`.
    final class Grant: Sendable {
        private let state = Mutex(true)
        var value: Bool { state.withLock { $0 } }
        func set(_ value: Bool) { state.withLock { $0 = value } }
    }

    private let grant: Grant
    func setTrusted(_ value: Bool) { grant.set(value) }

    /// A fresh handle on the same named pasteboard; the keeper has its own.
    var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    /// The user copying `text`.
    func userCopies(_ text: String) {
        let pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Plain text on the clipboard. Only for when it is not our promise:
    /// reading that would count as the target app's read.
    var clipboard: String? { pasteboard.string(forType: .string) }

    /// Whether the pasteboard still holds a transcript, by its markers,
    /// without reading the promise.
    var holdsTranscript: Bool {
        pasteboard.pasteboardItems?.first?.types.contains(Self.transient) == true
    }

    /// Lets the pending restore fall due, whenever that is, and waits for it.
    func restoreFallsDue() async {
        let task = await output.keeper.pendingRestore
        clock.advance(by: .seconds(60))
        await task?.value
    }

    /// The target app reading the transcript now.
    func targetReads() async {
        guard let promise = await output.keeper.pendingPromise else { return }
        await output.keeper.transcriptRead(promise, at: clock.now)
    }

    func release() { pasteboard.releaseGlobally() }
}
