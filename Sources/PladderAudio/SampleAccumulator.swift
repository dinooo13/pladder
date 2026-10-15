import Synchronization

// A drain copies out and keeps the buffer, so the audio thread appends into memory
// already reserved. The copy, about a second of audio, is all the work under the lock.
final class SampleAccumulator: Sendable {
    // The first drain comes after a second, so the audio thread rarely grows the array.
    static let defaultCapacity = 160_000

    private let samples: Mutex<[Float]>

    init(capacity: Int = SampleAccumulator.defaultCapacity) {
        var reserved: [Float] = []
        reserved.reserveCapacity(capacity)
        samples = Mutex(reserved)
    }

    // Realtime audio thread.
    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        samples.withLock { $0.append(contentsOf: newSamples) }
    }

    func drain() -> [Float] {
        samples.withLock { buffer in
            // Through the pointer, not `Array(buffer)`: that would share the storage, and the
            // `removeAll` below would then allocate a new buffer instead of emptying this one.
            let taken = buffer.withUnsafeBufferPointer { Array($0) }
            buffer.removeAll(keepingCapacity: true)
            return taken
        }
    }

    var capacity: Int {
        samples.withLock { $0.capacity }
    }
}
