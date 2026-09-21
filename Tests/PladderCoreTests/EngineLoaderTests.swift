import Foundation
import Testing
@testable import PladderCore

@MainActor
@Suite struct EngineLoaderTests {
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
}
