import Foundation
import Synchronization
import Testing

@testable import PladderAudio

/// The capture's sample hand-off, without a microphone: these append what a
/// tap block would and drain the way the capture actor does.
@Suite("SampleAccumulator", .timeLimit(.minutes(1)))
struct SampleAccumulatorTests {
    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map(Float.init)
    }

    @Test("A drain returns what came since the previous drain")
    func drainReturnsWhatCameSinceThePreviousDrain() {
        let accumulator = SampleAccumulator(capacity: 100)
        #expect(accumulator.drain().isEmpty)
        accumulator.append(ramp(0..<10))
        accumulator.append(ramp(10..<16))
        #expect(accumulator.drain() == ramp(0..<16))
        accumulator.append(ramp(16..<20))
        #expect(accumulator.drain() == ramp(16..<20))
        #expect(accumulator.drain().isEmpty)
    }

    @Test("The drain at stop returns only the tail")
    func stopReturnsOnlyTheTail() {
        let accumulator = SampleAccumulator(capacity: 100)
        accumulator.append(ramp(0..<30))
        _ = accumulator.drain()
        accumulator.append(ramp(30..<34))
        #expect(accumulator.drain() == ramp(30..<34))
    }

    @Test("A drain keeps the reserved buffer")
    func drainKeepsCapacity() {
        let accumulator = SampleAccumulator(capacity: 1_000)
        #expect(accumulator.capacity >= 1_000)
        accumulator.append(ramp(0..<600))
        let drained = accumulator.drain()
        #expect(drained.count == 600)
        #expect(accumulator.capacity >= 1_000)
        // The drained copy is the caller's own, so emptying and refilling the
        // accumulator leaves it as it was.
        accumulator.append(ramp(600..<900))
        #expect(drained == ramp(0..<600))
        #expect(accumulator.drain() == ramp(600..<900))
        #expect(accumulator.capacity >= 1_000)
    }

    @Test("Drains racing the audio thread neither lose nor repeat a sample")
    func concurrentDrainsLoseNothing() async {
        let accumulator = SampleAccumulator(capacity: 256)
        let chunks = 500
        let chunkSize = 683  // what one 2048-frame tap buffer at 48 kHz becomes
        let finished = Flag()
        let producer = Task.detached {
            for chunk in 0..<chunks {
                accumulator.append((chunk * chunkSize..<(chunk + 1) * chunkSize).map(Float.init))
            }
            finished.value.store(true, ordering: .releasing)
        }
        var collected: [Float] = []
        while !finished.value.load(ordering: .acquiring) {
            collected.append(contentsOf: accumulator.drain())
            await Task.yield()
        }
        await producer.value
        // The drain at stop, after the last buffer.
        collected.append(contentsOf: accumulator.drain())
        #expect(collected.count == chunks * chunkSize)
        #expect(collected == ramp(0..<chunks * chunkSize))
    }
}

private final class Flag: Sendable {
    let value = Atomic(false)
}
