import Foundation
import Synchronization

// Every wait ends by itself after `limit`, so a regression fails rather than hangs.
public actor Gate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var timers: [Task<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    public private(set) var arrivals = 0

    public init() {}

    public func wait(atMost limit: Duration = .seconds(2)) async {
        arrivals += 1
        for watcher in watchers { watcher.resume() }
        watchers = []
        if isOpen { return }
        let id = UUID()
        timers.append(Task {
            try? await Task.sleep(for: limit)
            self.release(id)
        })
        await withCheckedContinuation { waiters[id] = $0 }
    }

    public func open() {
        isOpen = true
        for waiter in waiters.values { waiter.resume() }
        waiters = [:]
        for timer in timers { timer.cancel() }
        timers = []
    }

    public func untilSomeoneWaits() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

public final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    public init() {}

    public func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    public var all: [Value] {
        values.withLock { $0 }
    }
}

public func scratchDirectory(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "\(name)-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Polls in real time: the fakes' counters are not observable.
@MainActor
public func waitUntil(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// Polls in real time, a millisecond at a time for up to about two seconds, for what a
// detached task does on its own schedule.
public func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
