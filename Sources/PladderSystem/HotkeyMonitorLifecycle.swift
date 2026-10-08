import Foundation
import PladderCore

/// The session bookkeeping both hotkey monitors share.
///
/// A session runs from `start` to `stop`, or until its consumer drops the
/// stream. Its OS resource, the tap or the Carbon handler with its hot keys,
/// is made on another thread after `start` has returned, so every session has
/// a generation: the thread making the resource asks `needsResource` first,
/// and `adopt` refuses a resource made for a session that has ended
/// meanwhile, which the caller then takes straight down. Per-session state
/// lives here too, behind the same lock as the continuation, so an event
/// handler reads both at once.
///
/// Every session that ends goes the same way, whether `stop`, a restart or
/// the stream's termination ended it: the continuation finishes, the
/// resource is torn down and `ended` is handed the state. A dropped stream
/// used to take only the resource down, leaving a pending tap install to
/// come up for nobody and Carbon's Escape registered.
///
/// `@unchecked Sendable`: everything mutable is behind `lock`.
final class HotkeyMonitorLifecycle<Resource: Sendable, State: Sendable>: @unchecked Sendable {
    typealias Continuation = AsyncStream<HotkeyMonitorEvent>.Continuation

    /// The current session, as `withSession` hands it out.
    struct Session {
        let generation: UInt64
        let continuation: Continuation
        fileprivate(set) var resource: Resource?
        var state: State

        /// Lets optional chaining mutate the stored session in place.
        fileprivate mutating func apply<T>(_ body: (inout Session) -> T) -> T { body(&self) }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var session: Session?
    private let tearDown: @Sendable (Resource) -> Void
    private let ended: @Sendable (State) -> Void

    /// `tearDown` takes an adopted resource down, on whichever thread it
    /// belongs to; it is called once per adopted resource. `ended` gets the
    /// state of every session that ends, for anything in it that also has to
    /// be taken down.
    init(
        tearDown: @escaping @Sendable (Resource) -> Void,
        ended: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.tearDown = tearDown
        self.ended = ended
    }

    /// Ends the current session, if any, and begins a new one with the state
    /// `makeState` builds for its generation. `makeState` runs under the lock.
    func start(
        _ makeState: (UInt64) -> State
    ) -> (stream: AsyncStream<HotkeyMonitorEvent>, generation: UInt64) {
        stop()
        let (stream, continuation) = AsyncStream<HotkeyMonitorEvent>.makeStream(
            bufferingPolicy: .unbounded)
        let generation: UInt64 = lock.withLock {
            generation &+= 1
            session = Session(
                generation: generation, continuation: continuation,
                resource: nil, state: makeState(generation))
            return generation
        }
        // If the consumer drops the stream the resource must still go.
        continuation.onTermination = { [weak self] _ in self?.end(generation) }
        return (stream, generation)
    }

    func stop() { end(nil) }

    /// True while `generation` is the current session and has no resource
    /// yet. Asked before making one, so a superseded start makes nothing.
    func needsResource(_ generation: UInt64) -> Bool {
        lock.withLock { session?.generation == generation && session?.resource == nil }
    }

    /// Hands a resource made for `generation` to its session. False when
    /// that session ended meanwhile: the resource is then the caller's to
    /// take down, on the thread it is on.
    func adopt(_ resource: Resource, for generation: UInt64) -> Bool {
        lock.withLock {
            guard session?.generation == generation, session?.resource == nil else { return false }
            session?.resource = resource
            return true
        }
    }

    /// Runs `body` on the current session under the lock, or on session
    /// `generation` only; nil when there is no such session. `body` must not
    /// call back into this lifecycle.
    func withSession<T>(_ generation: UInt64? = nil, _ body: (inout Session) -> T) -> T? {
        lock.withLock {
            guard generation == nil || session?.generation == generation else { return nil }
            return session?.apply(body)
        }
    }

    /// Ends the session `generation`, or whichever is current for nil.
    private func end(_ generation: UInt64?) {
        let ending: Session? = lock.withLock {
            guard let current = session, generation == nil || current.generation == generation
            else { return nil }
            session = nil
            return current
        }
        guard let ending else { return }
        // `finish()` runs `onTermination` synchronously; the session is
        // already gone and the lock released, so that is a no-op.
        ending.continuation.finish()
        if let resource = ending.resource { tearDown(resource) }
        ended(ending.state)
    }
}
