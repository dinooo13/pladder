import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

/// The coordinator's hand-overs between tasks, each of which once lost or
/// misplaced a dictation, and its timers driven by `ManualClock`, so a test
/// can prove a timer did not fire without waiting for it.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CoordinatorHandOverTests {
    // MARK: The release and the feed

    @Test func aChunkInFlightAtTheReleaseReachesTheEngineBeforeTheEnd() async {
        let engine = FakeStreamingEngine(feedDelay: .milliseconds(150))
        let (c, output, _, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        await c.startIdle()
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
        await c.startIdle()
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
        await c.startIdle()
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
        await c.startIdle()
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

    // Before: each cancel's cleanup replaced the one before, so a press
    // waited for the newest only. An older cleanup still waiting for its
    // feed then dropped the utterance after the next recording had begun
    // one, and that dictation failed as "not loaded".
    @Test func aPressWaitsForEveryEarlierCancel() async {
        let engine = FakeStreamingEngine(feedDelay: .milliseconds(300))
        let (c, output, _, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        await c.startIdle()
        // Cancelled while the feed is inside the engine: its cleanup waits
        // for the feed before it drops the utterance.
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.isFeeding })
        let first = Task { await c.cancelRecording() }
        #expect(await waitUntil { c.state == .idle })
        // Waits for that cleanup, and is cancelled before its microphone is
        // up, so its own cleanup has nothing to wait for but the first.
        let second = Task { await c.hotkeyPressed() }
        #expect(await waitUntil { c.state.isRecording })
        let secondCancel = Task { await c.cancelRecording() }
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.hotkeyReleased()
        await c.inFlight?.value
        _ = await (first.value, second.value, secondCancel.value)
        #expect(output.inserted == ["final"])
        let lifecycle = engine.log.filter { ["begin", "abandon", "stale abandon", "end"].contains($0) }
        #expect(lifecycle == ["begin", "abandon", "begin", "end"])
    }

    // Before: a press cancelled while it waited for a cleanup went on to
    // start the microphone, and so restarted the capture of the recording
    // that had started since, dropping what it had buffered.
    @Test func aPressCancelledWhileItWaitsLeavesTheMicrophoneAlone() async {
        let (c, _, capture) = makeCoordinator()
        await capture.setStopDelay(.milliseconds(150))
        await c.startIdle()
        await c.hotkeyPressed()
        let cancel = Task { await c.cancelRecording() }
        #expect(await waitUntil { c.state == .idle })
        let cancelledPress = Task { await c.hotkeyPressed() }
        #expect(await waitUntil { c.state.isRecording })
        let cancelPress = Task { await c.cancelRecording() }
        #expect(await waitUntil { c.state == .idle })
        let press = Task { await c.hotkeyPressed() }
        #expect(await waitUntil { c.state.isRecording })
        _ = await (cancel.value, cancelledPress.value, cancelPress.value, press.value)
        #expect(c.state.isRecording)
        #expect(await capture.startCount == 2)
        await c.cancelRecording()
    }

    // Before: the engine kept one utterance and no handle, so the abandon
    // of a recording cancelled while its utterance began, landing after
    // the next recording had begun its own, dropped that one instead.
    @Test func aLateAbandonOfACancelledUtteranceLeavesTheNextOne() async {
        let engine = FakeStreamingEngine(beginDelay: .milliseconds(100), abandonDelay: .milliseconds(300))
        let (c, output, _, _) = await makeStreamingCoordinator(style: .compact, engine: engine)
        await c.startIdle()
        let cancelled = Task { await c.hotkeyPressed() }
        #expect(await waitUntil { engine.log.contains("begin") })
        await c.cancelRecording()
        // Its utterance begins anyway, and the abandon that follows lands
        // late.
        #expect(await waitUntil { engine.abandonCalls == 1 })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        #expect(await waitUntil { engine.log.contains("stale abandon") })
        c.hotkeyReleased()
        await c.inFlight?.value
        await cancelled.value
        #expect(output.inserted == ["final"])
        #expect(!engine.log.contains("abandon"))
    }

    @Test func cancelAbandonsTheEngineThatRecordedAndOnlyOnce() async {
        let first = FakeStreamingEngine(id: EngineID("first"))
        let second = FakeStreamingEngine(id: EngineID("second"))
        let (c, _, _) = makeCoordinator(engines: [.serving(first), .serving(second)])
        c.feedInterval = .milliseconds(10)
        await c.startIdle()
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
        await c.startIdle()
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
            await c.startIdle()
            await c.dictate(submit: submit)
            let insertion = events.lastInsertion
            #expect(insertion?.result == result)
            #expect(insertion?.submitted == submitted)
            #expect(insertion?.transcript.text == "hello world")
        }
    }

    // MARK: Settings and the monitor

    // Before: any dictation setting rebuilt them, compiling a regex per
    // dictionary entry, although only the dictionary goes into them.
    @Test func onlyADictionaryChangeRebuildsTheProcessors() async {
        let builds = Recorder<DictationSettings>()
        let (c, _, _) = makeCoordinator(makePipeline: { builds.append($0); return ProcessorPipeline([]) })
        #expect(builds.all.count == 1)
        c.settings = c.settings
        c.settings.appendTrailingSpace.toggle()
        c.settings.disabledProcessors = [FillerRemover.processorID]
        c.settings.liveTranscript.toggle()
        c.settings.hotkey = .rightOption
        #expect(builds.all.count == 1)
        let dictionary = [DictionaryEntry(from: "a", to: "b")]
        c.settings.dictionary = dictionary
        #expect(builds.all.count == 2)
        #expect(builds.all.last?.dictionary == dictionary)
    }

    @Test func aCombinedUpdateRestartsTheMonitorOnce() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        await c.startIdle()
        var settings = c.settings
        settings.hotkey = .rightOption
        settings.submitKey = Hotkey(0x0B)
        settings.toggleHotkey = Hotkey(0x3B, 0x02)
        settings.dictionary = [DictionaryEntry(from: "a", to: "b")]
        c.update(settings, hotkeyOverride: .optionSpace)
        #expect(fake.startCount == 2)
        #expect(fake.lastChords == [.dictate: .optionSpace, .toggle: Hotkey(0x3B, 0x02)])
    }

    // Before: the app swapped the monitor for a new chord only at the next
    // permission poll, up to two seconds later. Under Secure Event Input a
    // modifier-only chord recorded while Carbon was in charge was handed to
    // Carbon, which cannot register it, and nothing listened until then.
    @Test func aChordAndTheMonitorItNeedsChangeInOneRestart() async {
        let carbon = FakeHotkey()
        let tap = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: carbon)
        await c.startIdle()
        var settings = c.settings
        settings.hotkey = .rightCommand
        c.update(settings, hotkeyOverride: nil, monitor: tap)
        #expect(carbon.startedHotkeys == [.optionSpace])
        #expect(carbon.stopCount >= 1)
        #expect(tap.startedHotkeys == [.rightCommand])
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
        await c.startIdle()
        await c.dictate()
        await c.hotkeyPressed()
        await c.cancelRecording()
        #expect(await waitUntil { muter.endedCount == 2 })
        #expect(muter.startedSessions.count == 2)
        #expect(Set(muter.startedSessions) == Set(muter.endedSessions))
        #expect(muter.startedSessions[0] < muter.startedSessions[1])
    }

    // MARK: Quitting

    @Test func shutdownWhileRecordingGivesBackTheSpeakersAndTheClipboard() async {
        let muter = FakeOutputMuter()
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.muteOutputWhileDictating = true
        let (c, output, capture) = makeCoordinator(settings: settings, outputMuter: muter)
        await c.startIdle()
        await c.hotkeyPressed()
        await c.shutdown()
        #expect(await capture.stopCount == 1)
        #expect(muter.endedCount >= 1)
        #expect(output.flushCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func shutdownLetsADictationOnItsWayOutFinish() async {
        let (c, output, _) = makeCoordinator()
        await c.startIdle()
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.shutdown()
        #expect(output.inserted == ["hello world "])
        #expect(output.flushCount == 1)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CoordinatorClockTests {
    @Test func theCapFiresOnTheClockAndNotBefore() async {
        let clock = ManualClock()
        let (c, output, _) = makeCoordinator(clock: clock)
        await c.startIdle()
        await c.hotkeyPressed()
        // The cap and the warm loop are both waiting.
        #expect(await waitUntil { clock.sleeperCount >= 2 })
        clock.advance(by: c.maximumDuration - .seconds(1))
        #expect(c.state.isRecording)
        clock.advance(by: .seconds(1))
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [false])
    }

    @Test func theCopiedHintLeavesOnTheClock() async {
        let clock = ManualClock()
        let output = FakeOutput()
        output.result = .copied
        let (c, _, _) = makeCoordinator(output: output, clock: clock)
        c.settings.copiedHoldDuration = .seconds(1)
        await c.startIdle()
        await c.dictate()
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
        await c.startIdle()
        await c.dictate()
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
        await c.startIdle()
        await c.dictate()
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
        let (c, _, _, engine) = makeCountingCoordinator(clock: clock)
        let warmPasses = { engine.calls.filter { $0 == 8_000 }.count }
        await c.startIdle()
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
        await c.startIdle()
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
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
    }

    @Test func aBounceInsideTheWindowKeepsTheRecordingWhateverTheClockDoes() async {
        let clock = ManualClock()
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(hotkeyMonitor: hotkey, clock: clock)
        c.deferReleases = true
        await c.startIdle()
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
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
    }
}
