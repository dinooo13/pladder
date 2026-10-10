import Foundation

/// Runs async work one piece at a time, in the order it was handed over.
///
/// Two `Task`s started one after the other reach an actor in no promised
/// order. Where the order is the meaning, as with a model file's download
/// cancelled and then wanted again when polish goes off and on within one
/// run-loop turn, each piece is enqueued here and starts only once the one
/// before it has finished.
@MainActor
public final class OrderedTasks {
    private var tail: Task<Void, Never>?

    public init() {}

    /// Starts `work` after everything enqueued before it.
    public func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Returns once everything enqueued so far has run.
    public func drained() async {
        await tail?.value
    }
}
