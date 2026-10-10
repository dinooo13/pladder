import Foundation
import Observation
import Testing
@testable import PladderSystem

@MainActor @Observable private final class Meter {
    var level: Float = 0
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ObservationLoopTests {
    // The loop acts on a task of its own, so each change needs a moment to land.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }

    @Test func everyChangeIsReportedOnce() async {
        let meter = Meter()
        let loop = ObservationLoop()
        var calls = 0
        loop.start { _ = meter.level } onChange: { calls += 1 }
        meter.level = 0.5
        await settle()
        meter.level = 0.6
        await settle()
        #expect(calls == 2)
    }

    @Test func aStopAndStartLeavesOneChain() async {
        let meter = Meter()
        let loop = ObservationLoop()
        var calls = 0
        loop.start { _ = meter.level } onChange: { calls += 1 }
        loop.stop()
        loop.start { _ = meter.level } onChange: { calls += 1 }
        meter.level = 0.5
        await settle()
        #expect(calls == 1)
        meter.level = 0.6
        await settle()
        #expect(calls == 2)
        meter.level = 0.7
        await settle()
        #expect(calls == 3)
    }

    @Test func nothingAfterStop() async {
        let meter = Meter()
        let loop = ObservationLoop()
        var calls = 0
        loop.start { _ = meter.level } onChange: { calls += 1 }
        loop.stop()
        meter.level = 0.5
        await settle()
        #expect(calls == 0)
    }
}
