import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

private actor Downloads {
    private(set) var running = false
    private let windDown: Gate

    init(windDown: Gate) { self.windDown = windDown }

    func ensure() { running = true }
    // Winding down, as a cancelled URLSession task does, and only then marked stopped.
    func cancel() async {
        await windDown.wait()
        running = false
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OrderedTasksTests {
    @Test func aCancelThenEnsureLeavesTheDownloadRunning() async {
        let windDown = Gate()
        let downloads = Downloads(windDown: windDown)
        await downloads.ensure()
        let tasks = OrderedTasks()
        tasks.enqueue { await downloads.cancel() }
        tasks.enqueue { await downloads.ensure() }
        await windDown.untilSomeoneWaits()
        await windDown.open()
        await tasks.drained()
        #expect(await downloads.running)
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
