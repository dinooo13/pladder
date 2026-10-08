import Synchronization

/// The 16 kHz samples a recording has captured and not yet handed out.
///
/// The tap block appends on the realtime audio thread; the capture actor
/// drains about once a second while the key is held and once more at stop.
/// One accumulator lives for the whole recording, across device changes, so
/// a switch of microphone swaps the tap in front of it without losing or
/// repeating anything said before the switch.
///
/// A drain copies the samples out and keeps the buffer, so the audio thread
/// goes on appending into memory that is already reserved and touched rather
/// than growing a fresh array from nothing every second. The copy is the
/// only work done under the lock: about a second of audio, 64 KB.
final class SampleAccumulator: Sendable {
    /// Ten seconds of 16 kHz mono: a dictation's first drain comes after one
    /// second, so the audio thread rarely has to grow the array.
    static let defaultCapacity = 160_000

    private let samples: Mutex<[Float]>

    init(capacity: Int = SampleAccumulator.defaultCapacity) {
        var reserved: [Float] = []
        reserved.reserveCapacity(capacity)
        samples = Mutex(reserved)
    }

    /// Called on the realtime audio thread.
    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        samples.withLock { $0.append(contentsOf: newSamples) }
    }

    /// Everything appended since the previous drain, oldest first.
    func drain() -> [Float] {
        samples.withLock { buffer in
            // A copy through the pointer, not `Array(buffer)`: that would
            // share the storage, and the `removeAll` below would then have to
            // allocate a new buffer instead of emptying this one.
            let taken = buffer.withUnsafeBufferPointer { Array($0) }
            buffer.removeAll(keepingCapacity: true)
            return taken
        }
    }

    /// The reserved buffer's size, for the tests.
    var capacity: Int {
        samples.withLock { $0.capacity }
    }
}
