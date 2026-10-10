import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

/// The shape of `ModelFiles`: `ensure` returns at once while a download is
/// running, and `cancel` takes it back.
private actor Downloads {
    private(set) var running = false
    func ensure() { running = true }
    func cancel() async {
        running = false
        // Winding down, as a cancelled URLSession task does.
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OrderedTasksTests {
    // Before: polish off and on within one run-loop turn fired the cancel
    // and the ensure as two tasks, and when the ensure reached the actor
    // first, the cancel then killed the download it had kept.
    @Test func aCancelThenEnsureLeavesTheDownloadRunning() async {
        for _ in 0..<50 {
            let downloads = Downloads()
            await downloads.ensure()
            let tasks = OrderedTasks()
            tasks.enqueue { await downloads.cancel() }
            tasks.enqueue { await downloads.ensure() }
            await tasks.drained()
            #expect(await downloads.running)
        }
    }

    @Test func eachPieceStartsAfterThePreviousOneFinished() async {
        let gate = Gate()
        let order = Recorder<String>()
        let tasks = OrderedTasks()
        tasks.enqueue {
            await gate.wait()
            order.append("first")
        }
        tasks.enqueue { order.append("second") }
        await gate.untilSomeoneWaits()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(order.all.isEmpty)
        await gate.open()
        await tasks.drained()
        #expect(order.all == ["first", "second"])
    }
}
