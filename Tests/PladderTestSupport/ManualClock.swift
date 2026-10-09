import Foundation
import Synchronization

/// A clock that only moves when a test says so. Sleepers wake when
/// `advance(by:)` carries `now` past their deadline, and at once when their
/// task is cancelled, so a timer can be fired, or proven not to fire, without
/// the test waiting for it. Its instants are `ContinuousClock`'s, so code that
/// stores them, as the paste does, takes this clock in place of the real one.
public final class ManualClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Instant
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they got as far as waiting.
        var cancelled: Set<Int> = []
    }

    private let state: Mutex<State>
    public let start: Instant

    public init() {
        let start = ContinuousClock.now
        self.start = start
        state = Mutex(State(now: start))
    }

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Deadlines somebody is asleep until right now.
    public var deadlines: [Instant] { state.withLock { $0.sleepers.map(\.deadline) } }

    /// How many sleeps are waiting, so a test can know a timer is armed
    /// before it advances past it.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Moves time on and wakes everyone whose deadline it reached.
    public func advance(by duration: Duration) {
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
    public func advance(to offset: Duration) {
        advance(by: start + offset - now)
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early = state.withLock { state -> Result<Void, any Error>? in
                    if state.cancelled.remove(id) != nil || Task.isCancelled { return .failure(CancellationError()) }
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
    public func waitForSleeper(at offset: Duration) async -> Bool {
        let deadline = start + offset
        return await eventually { self.deadlines.contains(deadline) }
    }
}

/// Polls `condition` for up to about two seconds of real time, a millisecond
/// at a time, for what a detached task does on its own schedule.
public func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
