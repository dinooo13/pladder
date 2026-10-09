import Foundation

/// A clock that only moves when a test says so. Sleepers wake when
/// `advance(by:)` carries `now` past their deadline, and at once when their
/// task is cancelled, so a coordinator timer can be fired, or proven not to
/// fire, without the test waiting for it.
final class ManualClock: Clock, @unchecked Sendable {
    // `@unchecked`: every field is behind `lock`.
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    /// Ids whose task was cancelled before their continuation was stored.
    private var cancelledEarly: Set<Int> = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// How many sleeps are waiting, so a test can know a timer is armed
    /// before it advances past it.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = lock.withLock {
                    if cancelledEarly.remove(id) != nil || Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let woken = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return woken
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
