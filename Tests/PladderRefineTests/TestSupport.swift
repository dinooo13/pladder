import Foundation
import Synchronization

/// Holds a stand-in until the test lets it go, for a load or a download that
/// must still be running at a given moment. Every wait ends by itself after
/// `limit`, so a regression that waits on the stand-in fails its
/// expectations instead of hanging the run: a time limit cannot end a test
/// stuck on a continuation. Passing tests open the gate long before.
actor Gate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var timers: [Task<Void, Never>] = []

    func wait(atMost limit: Duration = .seconds(2)) async {
        if isOpen { return }
        let id = UUID()
        timers.append(Task {
            try? await Task.sleep(for: limit)
            self.release(id)
        })
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func open() {
        isOpen = true
        for waiter in waiters.values { waiter.resume() }
        waiters = [:]
        for timer in timers { timer.cancel() }
        timers = []
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// Collects values from stand-ins on any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}

func scratchDirectory(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "\(name)-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
