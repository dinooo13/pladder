import Foundation
import Testing
@testable import PladderCore

@MainActor
@Suite struct EngineLoaderTests {
    private func makeLoader(failures: Int = 0, id: EngineID = EngineID("flaky")) -> EngineLoader {
        var statuses: [EngineStatus] = []
        let loader = EngineLoader(
            registry: EngineRegistry([
                .init(id: EngineID("flaky"), displayName: "Flaky", detail: "") { FlakyEngine(failures: failures) },
                .init(id: EngineID("echo"), displayName: "Echo", detail: "") { EchoEngine(delay: .milliseconds(5)) },
            ]),
            engineID: id)
        loader.onStatusChange = { statuses.append($0) }
        return loader
    }

    @Test func loadReachesReady() async {
        let loader = makeLoader(id: EngineID("echo"))
        loader.load()
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.status != .ready && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.status == .ready)
#expect(loader.engine.id == EngineID("echo"))
    }

    @Test func loadFailureReportsTheEngineMessage() async {
        let loader = makeLoader(failures: 1)
        loader.load()
        let deadline = ContinuousClock.now + .seconds(2)
        while !loader.status.isReady && loader.status != .failed(message: "boom") && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.status == .failed(message: "boom"))
    }

    @Test func reloadAfterFailureRecovers() async {
        let loader = makeLoader(failures: 1)
        loader.load()
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.status != .failed(message: "boom") && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.status == .failed(message: "boom"))
        loader.load()
        while loader.status != .ready && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.status == .ready)
    }

    @Test func selectReturnsThePreviousEngineAndLoadsTheNext() async {
        let loader = makeLoader(id: EngineID("echo"))
        loader.load()
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.status != .ready && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let previous = loader.select(EngineID("flaky"))
        #expect(previous != nil)
        #expect(previous?.id == EngineID("echo"))
        #expect(loader.engine.id == EngineID("flaky"))
        while loader.status != .ready && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.status == .ready)
    }
}
