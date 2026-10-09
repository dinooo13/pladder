import Foundation

// Not a task group: that waits for every child, so a model call ignoring cancellation
// would still hold the paste. Both tasks detached, so neither inherits the caller's actor.
func firstOf<Value: Sendable>(
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
