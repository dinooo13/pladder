import Foundation

/// Runs `work` against the wall clock: its value, or nil if `deadline` comes
/// first, and the task that ran it, cancelled either way. The polish models
/// race their calls with it, and quitting races the coordinator's shutdown.
///
/// Not a task group: that waits for every child before returning, so a
/// model call that ignores cancellation would still hold the paste. A
/// one-shot `AsyncStream` lets the loser be abandoned. Both tasks are
/// detached so neither inherits the caller's actor.
public func firstOf<Value: Sendable>(
    until deadline: ContinuousClock.Instant,
    priority: TaskPriority? = nil,
    _ work: @escaping @Sendable () async -> Value
) async -> (value: Value?, task: Task<Void, Never>) {
    let (stream, continuation) = AsyncStream<Value?>.makeStream()
    let task = Task.detached(priority: priority) {
        let value = await work()
        continuation.yield(value)
    }
    let timer = Task.detached {
        try? await Task.sleep(until: deadline, clock: .continuous)
        continuation.yield(nil)
    }
    defer {
        task.cancel()
        timer.cancel()
        continuation.finish()
    }
    var results = stream.makeAsyncIterator()
    return (await results.next() ?? nil, task)
}
