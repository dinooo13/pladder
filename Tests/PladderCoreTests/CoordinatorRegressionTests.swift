import Foundation
import Testing
@testable import PladderCore

/// The coordinator's hand-overs between tasks, each of which once lost or
/// misplaced a dictation, and its timers driven by `ManualClock`, so a test
/// can prove a timer did not fire without waiting for it.
@MainActor
@Suite struct CoordinatorHandOverTests {
    // MARK: The release and the feed

    @Test func aChunkInFlightAtTheReleaseReachesTheEngineBeforeTheEnd() async {
        let engine = FakeStreamingEngine(feedDelay: .milliseconds(150))
        let (c, output, _, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.isFeeding })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["final"])
        // Every chunk was handed over before the utterance was closed; the
        // engine never saw the end overtake a feed.
        let log = engine.log.filter { $0 == "fed" || $0 == "end" }
        #expect(log.last == "end")
        #expect(log.filter { $0 == "end" }.count == 1)
        #expect(!engine.isFeeding)
    }

    @Test func theFedCountIncludesTheChunkInFlightAtTheRelease() async {
        let engine = FakeStreamingEngine(feedDelay: .milliseconds(150))
        let (c, _, capture, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        // A tail under the minimum: only the fed audio can carry the
        // recording past it, so a chunk missing from the count drops it.
        await capture.setSamples([])
        c.minimumDuration = 0.4
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.isFeeding })
        c.hotkeyReleased()
        await c.inFlight?.value
        let fed = engine.feedCounts.reduce(0, +)
        #expect(fed == 8_000)
        #expect(c.lastTranscript?.audioDuration == Double(fed) / CapturedAudio.sampleRate)
    }

    @Test func noLivePassStartsAfterTheRelease() async {
        let engine = FakeStreamingEngine(feedDelay: .milliseconds(150))
        let (c, output, _, _) = await makeStreamingCoordinator(style: .liveTranscript, engine: engine)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.isFeeding })
        let passesAtRelease = engine.livePassCount
        c.hotkeyReleased()
        await c.inFlight?.value
        // The release waited for the feed loop to exit, so this is final.
        #expect(engine.livePassCount == passesAtRelease)
        #expect(output.inserted == ["final"])
    }

    // MARK: Cancel

    @Test func aPressRightAfterACancelKeepsItsUtterance() async {
        let engine = FakeStreamingEngine()
        let (c, output, capture, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        // A slow stop holds the cancel open while the next press comes.
        await capture.setStopDelay(.milliseconds(150))
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        let cancel = Task { await c.cancelRecording() }
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        await cancel.value
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["final"])
        // The cancelled utterance was dropped before the next one began, and
        // nothing dropped the next one.
        let lifecycle = engine.log.filter { ["begin", "abandon", "end"].contains($0) }
        #expect(lifecycle == ["begin", "abandon", "begin", "end"])
    }

    @Test func cancelAbandonsTheEngineThatRecordedAndOnlyOnce() async {
        let first = FakeStreamingEngine(id: EngineID("first"))
        let second = FakeStreamingEngine(id: EngineID("second"))
        let registry = EngineRegistry([
            .init(id: first.id, displayName: "First", detail: "") { first },
            .init(id: second.id, displayName: "Second", detail: "") { second },
        ])
        let c = DictationCoordinator(
            settings: DictationSettings(engineID: first.id), registry: registry,
            capture: FakeCapture(), output: FakeOutput(), hotkeyMonitor: FakeHotkey(),
            makePipeline: { _ in ProcessorPipeline([]) })
        c.feedInterval = .milliseconds(10)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.settings.engineID = second.id
        await c.cancelRecording()
        #expect(first.log.filter { $0 == "abandon" }.count == 1)
        #expect(!second.log.contains("abandon"))
    }

    // MARK: Engines that cannot stream this time

    @Test func aStreamingEngineThatCannotBeginIsTranscribedWhole() async {
        let engine = FakeStreamingEngine(beginFails: true)
        let events = EventLog()
        let (c, output, _, _) = await makeStreamingCoordinator(style: .compact, engine: engine, events: events)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["whole"])
        #expect(engine.feedCounts.isEmpty)
        #expect(engine.endCount == 0)
        #expect(!events.names.contains("failed"))
    }

    // MARK: The inserted event

    @Test func theInsertedEventSaysHowTheTextLanded() async {
        for (result, submit, submitted) in [(InsertResult.pasted, true, true), (.copied, true, false), (.pasted, false, false)] {
            let output = FakeOutput()
            output.result = result
            let events = EventLog()
            let (c, _, _) = makeCoordinator(output: output, events: events)
            c.start()
            #expect(await waitUntil { c.state == .idle })
            await c.hotkeyPressed()
            c.hotkeyReleased(submit: submit)
            await c.inFlight?.value
            guard case .inserted(let insertion) = events.events.last(where: { $0.isInserted }) else {
                Issue.record("no inserted event")
                continue
            }
            #expect(insertion.result == result)
            #expect(insertion.submitted == submitted)
            #expect(insertion.transcript.text == "hello world")
        }
    }

    // MARK: Settings and the monitor

    @Test func onlyARealChangeRebuildsTheProcessors() async {
        let builds = Counter()
        let c = DictationCoordinator(
            settings: DictationSettings(engineID: EchoEngine.engineID),
            registry: EngineRegistry([.init(id: EchoEngine.engineID, displayName: "Echo", detail: "") { EchoEngine() }]),
            capture: FakeCapture(), output: FakeOutput(), hotkeyMonitor: FakeHotkey(),
            makePipeline: { _ in builds.increment(); return ProcessorPipeline([]) })
        #expect(builds.value == 1)
        c.settings = c.settings
        #expect(builds.value == 1)
        c.settings.dictionary = [DictionaryEntry(from: "a", to: "b")]
        #expect(builds.value == 2)
    }

    @Test func changesBeforeStartRegisterOnceAtStart() async {
        let first = FakeHotkey()
        let second = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: first)
        c.hotkeyOverride = .rightOption
        c.replaceHotkeyMonitor(second)
        c.settings.toggleHotkey = Hotkey(0x31)
        #expect(first.startCount == 0)
        #expect(second.startCount == 0)
        c.start()
        #expect(second.startCount == 1)
        #expect(second.lastHotkey == .rightOption)
    }

    // MARK: The output muter

    @Test func eachRecordingsEndNamesItsOwnStart() async {
        let muter = FakeOutputMuter()
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.muteOutputWhileDictating = true
        let (c, _, _) = makeCoordinator(settings: settings, outputMuter: muter)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        await c.hotkeyPressed()
        await c.cancelRecording()
        #expect(await waitUntil { muter.endedCount == 2 })
        #expect(muter.startedSessions.count == 2)
        #expect(Set(muter.startedSessions) == Set(muter.endedSessions))
        #expect(muter.startedSessions[0] < muter.startedSessions[1])
    }

    @Test func theRealControllerNeverMutesForAnEndThatOvertookItsStart() async {
        // The two tasks the coordinator fires are unordered; this is the
        // order that once left the speakers muted for good.
        let control = RecordingMuteControl()
        let muter = OutputMuteController(control: control, delay: .milliseconds(1))
        await muter.recordingEnded(session: 1)
        await muter.recordingStarted(session: 1)
        #expect(control.applied.isEmpty)
    }

    // MARK: Quitting

    @Test func shutdownWhileRecordingGivesBackTheSpeakersAndTheClipboard() async {
        let muter = FakeOutputMuter()
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.muteOutputWhileDictating = true
        let (c, output, capture) = makeCoordinator(settings: settings, outputMuter: muter)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        await c.shutdown()
        #expect(await capture.stopCount == 1)
        #expect(muter.endedCount >= 1)
        #expect(output.flushCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func shutdownLetsADictationOnItsWayOutFinish() async {
        let (c, output, _) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.shutdown()
        #expect(output.inserted == ["hello world "])
        #expect(output.flushCount == 1)
    }
}

@MainActor
@Suite struct CoordinatorClockTests {
    @Test func theCapFiresOnTheClockAndNotBefore() async {
        let clock = ManualClock()
        let (c, output, _) = makeCoordinator(clock: clock)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        // The cap and the warm loop are both waiting.
        #expect(await waitUntil { clock.sleeperCount >= 2 })
        clock.advance(by: c.maximumDuration - .seconds(1))
        #expect(c.state.isRecording)
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { c.inFlight != nil })
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [false])
    }

    @Test func theCopiedHintLeavesOnTheClock() async {
        let clock = ManualClock()
        let output = FakeOutput()
        output.result = .copied
        let (c, _, _) = makeCoordinator(output: output, clock: clock)
        c.settings.copiedHoldDuration = .seconds(1)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .copied)
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .milliseconds(999))
        #expect(c.state == .copied)
        clock.advance(by: .milliseconds(1))
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func aPressDuringTheHintCancelsItsTimer() async {
        let clock = ManualClock()
        let output = FakeOutput()
        output.result = .copied
        let (c, _, _) = makeCoordinator(output: output, clock: clock)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        // Far past the hold: the hint's timer is gone, not just late.
        clock.advance(by: .seconds(30))
        await Task.yield()
        #expect(c.state.isRecording)
        await c.cancelRecording()
    }

    @Test func anErrorClearsOnTheClock() async {
        let clock = ManualClock()
        let output = FakeOutput()
        output.shouldFail = true
        let (c, _, _) = makeCoordinator(output: output, clock: clock)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .error(.other(detail: "paste failed")))
        #expect(c.lastError == .other(detail: "paste failed"))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: c.errorDisplayDuration - .milliseconds(1))
        #expect(c.state == .error(.other(detail: "paste failed")))
        clock.advance(by: .milliseconds(1))
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func theWarmLoopRunsOnTheClockAndStopsAtRelease() async {
        let clock = ManualClock()
        let engine = CountingEngine()
        let c = DictationCoordinator(
            settings: DictationSettings(engineID: CountingEngine.engineID),
            registry: EngineRegistry([.init(id: CountingEngine.engineID, displayName: "Counting", detail: "") { engine }]),
            capture: FakeCapture(), output: FakeOutput(), hotkeyMonitor: FakeHotkey(),
            makePipeline: { _ in ProcessorPipeline([]) }, clock: clock)
        let warmPasses = { engine.calls.filter { $0 == 8_000 }.count }
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        // One pass at key-down, then one per interval for as long as the key
        // is held.
        #expect(await waitUntil { warmPasses() == 1 })
        for expected in 2...4 {
            #expect(await waitUntil { clock.sleeperCount >= 2 })
            clock.advance(by: c.warmupInterval)
            #expect(await waitUntil { warmPasses() == expected })
        }
        c.hotkeyReleased()
        await c.inFlight?.value
        clock.advance(by: c.warmupInterval * 10)
        await Task.yield()
        #expect(warmPasses() == 4)
        #expect(engine.calls.last == 16_000)
    }

    @Test func aDeferredReleaseStopsWhenTheBounceWindowHasPassed() async {
        let clock = ManualClock()
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(hotkeyMonitor: hotkey, clock: clock)
        c.deferReleases = true
        c.start()
        #expect(await waitUntil { c.state == .idle })
        let pressed = ContinuousClock.now
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: pressed))
        #expect(await waitUntil { c.state.isRecording })
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .released(submit: false), instant: pressed + .seconds(1)))
        #expect(await waitUntil { c.handledHotkeyEvents == 2 })
        // Held for the bounce window, on the clock: the cap, the warm loop
        // and the settle are waiting.
        #expect(await waitUntil { clock.sleeperCount == 3 })
        #expect(c.state.isRecording)
        clock.advance(by: c.bounceWindow)
        #expect(await waitUntil { c.inFlight != nil })
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
    }

    @Test func aBounceInsideTheWindowKeepsTheRecordingWhateverTheClockDoes() async {
        let clock = ManualClock()
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(hotkeyMonitor: hotkey, clock: clock)
        c.deferReleases = true
        c.start()
        #expect(await waitUntil { c.state == .idle })
        let pressed = ContinuousClock.now
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: pressed))
        #expect(await waitUntil { c.state.isRecording })
        let released = pressed + .seconds(1)
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .released(submit: false), instant: released))
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: released + .milliseconds(10)))
        #expect(await waitUntil { c.handledHotkeyEvents == 3 })
        clock.advance(by: .seconds(5))
        await Task.yield()
        #expect(c.state.isRecording)
        #expect(output.inserted.isEmpty)
        // The real release after the bounce still stops, a window later.
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .released(submit: false), instant: released + .seconds(2)))
        #expect(await waitUntil { c.handledHotkeyEvents == 4 })
        #expect(await waitUntil { clock.sleeperCount == 3 })
        clock.advance(by: c.bounceWindow)
        #expect(await waitUntil { c.inFlight != nil })
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
    }
}

/// A device with one unmuted channel, recording every change made to it.
private final class RecordingMuteControl: OutputMuteControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [MuteState] = []
    var applied: [MuteState] { lock.withLock { _applied } }
    func defaultOutputDevice() -> UInt32? { 7 }
    func muteState(of device: UInt32) -> MuteState? { MuteState([1: false]) }
    func apply(_ state: MuteState, to device: UInt32) throws { lock.withLock { _applied.append(state) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private extension DictationCoordinator.Event {
    var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}
