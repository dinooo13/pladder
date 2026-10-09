import Foundation
import PladderCore

// A session's resource, the tap or Carbon's handler, is made on another thread after
// `start` returns: `needsResource` is asked first, and `adopt` refuses one made for a
// session that ended meanwhile. `@unchecked Sendable`: everything mutable is behind `lock`.
final class HotkeyMonitorLifecycle<Resource: Sendable, State: Sendable>: @unchecked Sendable {
    typealias Continuation = AsyncStream<HotkeyMonitorEvent>.Continuation

    struct Session {
        let generation: UInt64
        let continuation: Continuation
        fileprivate(set) var resource: Resource?
        var state: State

        // Lets optional chaining mutate the stored session in place.
        fileprivate mutating func apply<T>(_ body: (inout Session) -> T) -> T { body(&self) }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var session: Session?
    private let tearDown: @Sendable (Resource) -> Void
    private let ended: @Sendable (State) -> Void

    init(
        tearDown: @escaping @Sendable (Resource) -> Void,
        ended: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.tearDown = tearDown
        self.ended = ended
    }

    // `makeState` runs under the lock.
    func start(
        _ makeState: (UInt64) -> State
    ) -> (stream: AsyncStream<HotkeyMonitorEvent>, generation: UInt64) {
        stop()
        let (stream, continuation) = AsyncStream<HotkeyMonitorEvent>.makeStream(
            bufferingPolicy: .unbounded)
        let mine: UInt64 = lock.withLock {
            self.generation &+= 1
            let mine = self.generation
            session = Session(
                generation: mine, continuation: continuation,
                resource: nil, state: makeState(mine))
            return mine
        }
        // If the consumer drops the stream the resource must still go.
        continuation.onTermination = { [weak self] _ in self?.end(mine) }
        return (stream, mine)
    }

    func stop() { end(nil) }

    func needsResource(_ generation: UInt64) -> Bool {
        lock.withLock { session?.generation == generation && session?.resource == nil }
    }

    // False when that session ended meanwhile: the resource is then the caller's to take
    // down, on its own thread.
    func adopt(_ resource: Resource, for generation: UInt64) -> Bool {
        lock.withLock {
            guard session?.generation == generation, session?.resource == nil else { return false }
            session?.resource = resource
            return true
        }
    }

    // `body` runs under the lock and must not call back into this lifecycle.
    func withSession<T>(_ generation: UInt64? = nil, _ body: (inout Session) -> T) -> T? {
        lock.withLock {
            guard generation == nil || session?.generation == generation else { return nil }
            return session?.apply(body)
        }
    }

    private func end(_ generation: UInt64?) {
        let ending: Session? = lock.withLock {
            guard let current = session, generation == nil || current.generation == generation
            else { return nil }
            session = nil
            return current
        }
        guard let ending else { return }
        // `finish()` runs `onTermination` synchronously; the session is already gone and
        // the lock released, so that is a no-op.
        ending.continuation.finish()
        if let resource = ending.resource { tearDown(resource) }
        ended(ending.state)
    }
}
