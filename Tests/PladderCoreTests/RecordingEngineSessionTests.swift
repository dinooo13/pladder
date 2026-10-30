import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct RecordingEngineSessionTests {
    private func session(
        _ engine: any TranscriptionEngine, clock: ManualClock, live: Bool = false,
        partials: Recorder<String?> = Recorder()
    ) async -> RecordingEngineSession {
        let capture = FakeCapture()
        await capture.setDrainSamples(Array(repeating: 0.1, count: 8_000))
        return RecordingEngineSession(
            engine: engine, capture: capture, clock: clock,
            intervals: .init(feed: .seconds(1), livePass: .milliseconds(500), warmup: .seconds(2)),
            live: live, onPartial: { partials.append($0) })
    }

    private func loadedStreaming(
        feedGate: Gate? = nil, beginGate: Gate? = nil, beginFails: Bool = false
    ) async throws -> FakeStreamingEngine {
        let engine = FakeStreamingEngine(feedGate: feedGate, beginGate: beginGate, beginFails: beginFails)
        try await engine.load()
        return engine
    }

    @Test func theFeedLoopHandsOverEveryDrainedChunkOnce() async throws {
        let clock = ManualClock()
        let engine = try await loadedStreaming()
        let s = await session(engine, clock: clock)
        await s.begin()
        s.startLoops()
        for second in 1...3 {
            #expect(await clock.waitForSleeper(at: .seconds(second)))
            clock.advance(to: .seconds(second))
            #expect(await waitUntil { engine.feedCounts.count == second })
        }
        let ending = s.end()
        guard case .utterance = ending.source else {
            Issue.record("expected the utterance, got \(ending.source)")
            return
        }
        #expect(await ending.feed?.value == 24_000)
        #expect(engine.feedCounts == [8_000, 8_000, 8_000])
    }

    @Test func endCancelsTheWarmLoopBeforeReturning() async throws {
        let clock = ManualClock()
        let engine = try await loadedStreaming()
        let s = await session(engine, clock: clock)
        await s.begin()
        s.startLoops()
        #expect(await waitUntil { engine.warmPassCount == 1 })
        #expect(await clock.waitForSleeper(at: .seconds(2)))
        s.end()
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(10))
        #expect(engine.warmPassCount == 1)
    }

    @Test func aLivePassFinishingAfterEndPublishesNothing() async throws {
        let clock = ManualClock()
        let engine = try await loadedStreaming()
        let partials = Recorder<String?>()
        let s = await session(engine, clock: clock, live: true, partials: partials)
        await s.begin()
        s.startLoops()
        #expect(await waitUntil { partials.all == ["partial 1"] })
        let livePass = Gate()
        await engine.setLivePassGate(livePass)
        #expect(await clock.waitForSleeper(at: .milliseconds(500)))
        clock.advance(to: .milliseconds(500))
        #expect(await waitUntil { engine.livePassCount == 2 })
        let ending = s.end()
        await livePass.open()
        _ = await ending.feed?.value
        #expect(partials.all == ["partial 1"])
        #expect(engine.warmPassCount == 0)
    }

    @Test func aBatchEngineGetsOnlyTheWarmLoop() async throws {
        let clock = ManualClock()
        let engine = CountingEngine()
        try await engine.load()
        let s = await session(engine, clock: clock)
        await s.begin()
        s.startLoops()
        #expect(await waitUntil { engine.calls == [8_000] })
        let ending = s.end()
        guard case .whole = ending.source else {
            Issue.record("expected the whole buffer, got \(ending.source)")
            return
        }
        #expect(ending.feed == nil)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aStreamingEngineThatCannotBeginIsWarmedAndTranscribedWhole() async throws {
        let clock = ManualClock()
        let engine = try await loadedStreaming(beginFails: true)
        let s = await session(engine, clock: clock)
        await s.begin()
        s.startLoops()
        #expect(await waitUntil { engine.log.contains("transcribe") })
        let ending = s.end()
        guard case .whole = ending.source else {
            Issue.record("expected the whole buffer, got \(ending.source)")
            return
        }
        #expect(ending.feed == nil)
    }

    @Test func abandonWaitsForTheFeedBeforeDroppingTheUtterance() async throws {
        let clock = ManualClock()
        let feed = Gate()
        let engine = try await loadedStreaming(feedGate: feed)
        let s = await session(engine, clock: clock)
        await s.begin()
        s.startLoops()
        #expect(await clock.waitForSleeper(at: .seconds(1)))
        clock.advance(to: .seconds(1))
        #expect(await waitUntil { engine.isFeeding })
        let abandoning = Task { await s.end().abandon() }
        // Negative path: gives an abandon that wrongly skips the feed time to arrive.
        try? await Task.sleep(for: .milliseconds(20))
        await feed.open()
        await abandoning.value
        #expect(Array(engine.log.suffix(2)) == ["fed", "abandon"])
    }

    @Test func aBeginOvertakenByEndDropsItsUtteranceAndStartsNoLoop() async throws {
        let clock = ManualClock()
        let begin = Gate()
        let engine = try await loadedStreaming(beginGate: begin)
        let s = await session(engine, clock: clock)
        let beginning = Task { await s.begin() }
        #expect(await waitUntil { engine.log.contains("begin") })
        let ending = s.end()
        await begin.open()
        await beginning.value
        s.startLoops()
        guard case .whole = ending.source else {
            Issue.record("expected the whole buffer, got \(ending.source)")
            return
        }
        #expect(engine.log.last == "abandon")
        #expect(clock.sleeperCount == 0)
        #expect(engine.warmPassCount == 0)
    }
}
