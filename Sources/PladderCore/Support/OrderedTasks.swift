import Foundation

// Tasks started one after another reach an actor in no promised order; work enqueued here
// starts only once the piece before it has finished.
@MainActor
public final class OrderedTasks {
    private var tail: Task<Void, Never>?

    public init() {}

    public func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    public func drained() async {
        await tail?.value
    }
}
