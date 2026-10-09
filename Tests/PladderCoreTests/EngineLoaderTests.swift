import Foundation
import Testing
@testable import PladderCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct EngineLoaderTests {
    private func makeLoader(failures: Int = 0, id: EngineID = EngineID("flaky")) -> EngineLoader {
        EngineLoader(
            registry: EngineRegistry([
                .init(id: EngineID("flaky"), displayName: "Flaky", detail: "") { FlakyEngine(failures: failures) },
                .init(id: EngineID("echo"), displayName: "Echo", detail: "") { EchoEngine(delay: .milliseconds(5)) },
            ]),
            engineID: id)
    }

    @Test func loadReachesReady() async {
        let loader = makeLoader(id: EngineID("echo"))
        loader.load()
        #expect(await waitUntil { loader.status == .ready })
        #expect(loader.engine.id == EngineID("echo"))
    }

    @Test func loadFailureReportsTheEngineMessage() async {
        let loader = makeLoader(failures: 1)
        loader.load()
        #expect(await waitUntil { loader.status == .failed(.loadFailed(detail: "boom")) })
    }

    @Test func reloadAfterFailureRecovers() async {
        let loader = makeLoader(failures: 1)
        loader.load()
        #expect(await waitUntil { loader.status == .failed(.loadFailed(detail: "boom")) })
        loader.load()
        #expect(await waitUntil { loader.status == .ready })
    }

    @Test func selectReturnsThePreviousEngineAndLoadsTheNext() async {
        let loader = makeLoader(id: EngineID("echo"))
        loader.load()
        #expect(await waitUntil { loader.status == .ready })
        let previous = loader.select(EngineID("flaky"))
        #expect(previous != nil)
        #expect(previous?.id == EngineID("echo"))
        #expect(loader.engine.id == EngineID("flaky"))
        #expect(await waitUntil { loader.status == .ready })
    }

    @Test func aSupersededLoadLeavesTheNextEngineAlone() async {
        let first = GatedEngine(id: EngineID("first"), progress: 0.25)
        let second = GatedEngine(id: EngineID("second"), progress: 0.5)
        let loader = EngineLoader(
            registry: EngineRegistry([
                .init(id: first.id, displayName: "First", detail: "") { first },
                .init(id: second.id, displayName: "Second", detail: "") { second },
            ]),
            engineID: first.id,
            pollInterval: .milliseconds(10))
        loader.load()
        #expect(await waitUntil { loader.status == .downloading(progress: 0.25) })

        loader.select(second.id)
        #expect(await waitUntil { loader.status == .downloading(progress: 0.5) })

        await first.open()
        #expect(await first.waitUntilLoaded())
        // Time for the superseded load task to resume on the main actor.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(loader.engine.id == second.id)
        #expect(loader.status == .downloading(progress: 0.5))

        await second.report(progress: 0.75)
        #expect(await waitUntil { loader.status == .downloading(progress: 0.75) })
        await second.open()
        #expect(await waitUntil { loader.status == .ready })
    }
}

private actor GatedEngine: TranscriptionEngine {
    nonisolated let id: EngineID
    nonisolated let displayName = "Gated"
    private(set) var status: EngineStatus = .unloaded
    private var progress: Double
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(id: EngineID, progress: Double) {
        self.id = id
        self.progress = progress
    }

    func load() async throws {
        status = .downloading(progress: progress)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        status = .ready
    }

    func waitUntilLoaded() async -> Bool {
        for _ in 0..<100 {
            if status == .ready { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return status == .ready
    }

    func report(progress: Double) {
        self.progress = progress
        if case .downloading = status { status = .downloading(progress: progress) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        Transcript(text: "gated", audioDuration: 1, processingTime: 0, engineID: id)
    }

    func unload() { status = .unloaded }
}
