import Foundation
import Synchronization

public final class ManualClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Watcher {
        let id: Int
        let isMet: @Sendable ([Instant]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var now: Instant
        var nextID = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<Int> = []
        var watchers: [Watcher] = []
        var expired: Set<Int> = []

        mutating func takeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        mutating func takeMetWatchers() -> [Watcher] {
            let deadlines = sleepers.map(\.deadline)
            let met = watchers.filter { $0.isMet(deadlines) }
            watchers.removeAll { watcher in met.contains { $0.id == watcher.id } }
            return met
        }
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
    public var deadlines: [Instant] { state.withLock { $0.sleepers.map(\.deadline) } }
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

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

    public func advance(to offset: Duration) {
        advance(by: start + offset - now)
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { $0.takeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (early, met) = state.withLock { state -> (Result<Void, any Error>?, [Watcher]) in
                    if state.cancelled.remove(id) != nil || Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return (nil, state.takeMetWatchers())
                }
                for watcher in met { watcher.continuation.resume(returning: true) }
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

    public func waitForSleeper(at offset: Duration) async -> Bool {
        let deadline = start + offset
        return await waitFor { $0.contains(deadline) }
    }

    public func waitForSleepers(_ count: Int) async -> Bool {
        await waitFor { $0.count >= count }
    }

    private func waitFor(_ isMet: @escaping @Sendable ([Instant]) -> Bool) async -> Bool {
        let id = state.withLock { $0.takeID() }
        // Ends the wait after two seconds, as a `Gate` does, so a regression fails rather than hangs.
        let timeout = Task {
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            self.expire(id)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let early = state.withLock { state -> Bool? in
                if state.expired.remove(id) != nil { return false }
                if isMet(state.sleepers.map(\.deadline)) { return true }
                state.watchers.append(Watcher(id: id, isMet: isMet, continuation: continuation))
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }

    private func expire(_ id: Int) {
        let watcher = state.withLock { state -> Watcher? in
            if let index = state.watchers.firstIndex(where: { $0.id == id }) {
                return state.watchers.remove(at: index)
            }
            state.expired.insert(id)
            return nil
        }
        watcher?.continuation.resume(returning: false)
    }
}
