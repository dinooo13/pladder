import Foundation
import Testing
@testable import PladderCore

// MARK: - Fakes

actor FakeCapture: AudioCapture {
    var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000)
    var startCount = 0
    var stopCount = 0
    var levelContinuation: AsyncStream<Float>.Continuation?

    func start() async throws -> AsyncStream<Float> {
        startCount += 1
        let (stream, cont) = AsyncStream<Float>.makeStream()
        levelContinuation = cont
        return stream
    }

    func drain() async -> [Float] {
        []
    }

    func stop() async -> CapturedAudio {
        stopCount += 1
        levelContinuation?.finish()
        return CapturedAudio(samples: samplesToReturn)
    }

    func warmUp() async throws {}

    func setSamples(_ s: [Float]) { samplesToReturn = s }
    func emitLevel(_ l: Float) { levelContinuation?.yield(l) }
}

final class FakeOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: [String] = []
    private var _submitted: [Bool] = []
    private var _prepareCount = 0
    var inserted: [String] { lock.withLock { _inserted } }
    var submitted: [Bool] { lock.withLock { _submitted } }
    var prepareCount: Int { lock.withLock { _prepareCount } }
    var shouldFail = false
    /// What `insert` reports back: `.copied` stands in for an untrusted
    /// `PasteboardOutput`, which leaves the text on the clipboard.
    var result: InsertResult = .pasted

    @discardableResult
    func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        if shouldFail { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "paste failed"]) }
        lock.withLock {
            _inserted.append(text)
            _submitted.append(submit)
        }
        return result
    }

    func prepare() async {
        lock.withLock { _prepareCount += 1 }
    }
}

final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    /// How often `start` was called, and with what, so a monitor swap can be
    /// checked from the outside.
    private(set) var startCount = 0
    private(set) var lastHotkey: Hotkey?
    func start(hotkey: Hotkey, submitKey: Hotkey) -> AsyncStream<HotkeyEvent> {
        startCount += 1
        lastHotkey = hotkey
        let (stream, cont) = AsyncStream<HotkeyEvent>.makeStream()
        continuation = cont
        return stream
    }
    func stop() { continuation?.finish() }
    func press() { continuation?.yield(.pressed) }
    func release(submit: Bool = false) { continuation?.yield(.released(submit: submit)) }
}

/// Fails `load()` a set number of times, then succeeds.
actor FlakyEngine: TranscriptionEngine {
    nonisolated let id = EngineID("flaky")
    nonisolated let displayName = "Flaky"
    private(set) var status: EngineStatus = .unloaded
    private var failuresRemaining: Int
    init(failures: Int) { failuresRemaining = failures }
    struct LoadFailed: LocalizedError { var errorDescription: String? { "boom" } }
    func load() async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            status = .failed(message: "boom")
            throw LoadFailed()
        }
        status = .ready
    }
    func transcribe(_ samples: [Float]) async throws -> Transcript {
        Transcript(text: "flaky", audioDuration: 1, processingTime: 0, engineID: id)
    }
    func unload() { status = .unloaded }
}

/// Like `EchoEngine`, but records the sample count of every `transcribe` call
/// and can delay the transcription to simulate a long engine pass.
actor CountingEngine: TranscriptionEngine {
    static let engineID = EngineID("counting")
    nonisolated let id = CountingEngine.engineID
    nonisolated let displayName = "Counting"
    private(set) var status: EngineStatus = .unloaded
    private let recorder = SampleRecorder()
    private let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }
    nonisolated var calls: [Int] { recorder.callCounts }

    func load() async throws { status = .ready }
    func transcribe(_ samples: [Float]) async throws -> Transcript {
        recorder.append(samples.count)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return Transcript(text: "counted", audioDuration: Double(samples.count) / CapturedAudio.sampleRate, processingTime: 0, engineID: id)
    }
    func unload() { status = .unloaded }
}

/// Lock-protected so `calls` can be read synchronously from test assertions.
private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCounts: [Int] = []
    var callCounts: [Int] { lock.withLock { _callCounts } }
    func append(_ count: Int) { lock.withLock { _callCounts.append(count) } }
}

// MARK: - Helpers

@MainActor
private func makeCoordinator(
    engineText: String = "hello world",
    settings: Settings? = nil,
    output: FakeOutput = FakeOutput(),
    capture: FakeCapture = FakeCapture(),
    hotkeyMonitor: FakeHotkey? = nil
) -> (DictationCoordinator, FakeOutput, FakeCapture) {
    let registry = EngineRegistry([
        .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
            EchoEngine(text: engineText, delay: .milliseconds(5))
        }
    ])
    let settings = settings ?? Settings(engineID: EchoEngine.engineID)
    let coordinator = DictationCoordinator(
        settings: settings,
        registry: registry,
        capture: capture,
        output: output,
        hotkeyMonitor: hotkeyMonitor ?? FakeHotkey(),
        makePipeline: { s in
            ProcessorPipeline([DictionaryReplacer(entries: s.dictionary), WhitespaceNormalizer()])
        }
    )
    return (coordinator, output, capture)
}

/// Builds a coordinator around a CountingEngine.
@MainActor
private func makeCountingCoordinator(
    engineDelay: Duration = .zero
) -> (DictationCoordinator, FakeOutput, FakeCapture, CountingEngine) {
    let output = FakeOutput()
    let capture = FakeCapture()
    let engine = CountingEngine(delay: engineDelay)
    let registry = EngineRegistry([
        .init(id: CountingEngine.engineID, displayName: "Counting", detail: "") { engine }
    ])
    var settings = Settings(engineID: CountingEngine.engineID)
    settings.appendTrailingSpace = false
    let coordinator = DictationCoordinator(
        settings: settings,
        registry: registry,
        capture: capture,
        output: output,
        hotkeyMonitor: FakeHotkey(),
        makePipeline: { s in ProcessorPipeline([DictionaryReplacer(entries: s.dictionary), WhitespaceNormalizer()]) }
    )
    return (coordinator, output, capture, engine)
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Records the coordinator's events by name, for assertions about order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    var names: [String] { lock.withLock { _names } }

    func append(_ event: DictationCoordinator.Event) {
        let name: String
        switch event {
        case .recordingStarted: name = "recordingStarted"
        case .recordingStopped: name = "recordingStopped"
        case .inserted: name = "inserted"
        case .failed: name = "failed"
        }
        lock.withLock { _names.append(name) }
    }
}

// MARK: - Tests

@MainActor
@Suite struct DictationCoordinatorTests {
    @Test func startsUnavailableThenIdleWhenEngineReady() async {
        let (c, _, _) = makeCoordinator()
        #expect(c.state == .unavailable(reason: "Starting"))
        c.start()
        #expect(await waitUntil { c.state == .idle })
        #expect(c.engineStatus == .ready)
    }

    @Test func ignoresPressWhileEngineNotReady() async {
        let (c, _, capture) = makeCoordinator()
        await c.hotkeyPressed()
        #expect(c.state == .unavailable(reason: "Starting"))
        #expect(await capture.startCount == 0)
    }

    @Test func fullDictationCycleInsertsProcessedText() async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.dictionary = [DictionaryEntry(from: "hello world", to: "Hello, World!")]
        let (c, output, capture) = makeCoordinator(settings: settings)
        c.start()
        #expect(await waitUntil { c.state == .idle })

        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        #expect(await capture.startCount == 1)

        c.hotkeyReleased()
        #expect(c.state == .transcribing)
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted == ["Hello, World! "])
        #expect(c.lastTranscript?.text == "Hello, World!")
    }

    @Test func noTrailingSpaceWhenDisabled() async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["hello world"])
    }

    @Test func shortTapIsDiscarded() async {
        let (c, output, capture) = makeCoordinator()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(output.inserted.isEmpty)
    }

    @Test func levelUpdatesFlowIntoState() async {
        let (c, _, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        await capture.emitLevel(0.7)
        #expect(await waitUntil { c.state == .recording(level: 0.7) })
        c.hotkeyReleased()
        await c.inFlight?.value
    }

    @Test func copiedResultShowsTheHintThenIdles() async {
        let output = FakeOutput()
        output.result = .copied
        let (c, _, _) = makeCoordinator(output: output)
        c.copiedDisplayDuration = .milliseconds(50)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .copied)
        #expect(output.inserted.count == 1)
        #expect(c.lastTranscript?.text == "hello world")
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func copiedResultStillEmitsInserted() async {
        let output = FakeOutput()
        output.result = .copied
        let events = EventLog()
        let registry = EngineRegistry([
            .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
                EchoEngine(text: "hello world", delay: .milliseconds(5))
            }
        ])
        let c = DictationCoordinator(
            settings: Settings(engineID: EchoEngine.engineID),
            registry: registry,
            capture: FakeCapture(),
            output: output,
            hotkeyMonitor: FakeHotkey(),
            makePipeline: { _ in ProcessorPipeline([]) },
            onEvent: { [events] in events.append($0) }
        )
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(events.names.last == "inserted")
        #expect(!events.names.contains("failed"))
    }

    @Test func pressDuringCopiedHintStartsRecording() async {
        let output = FakeOutput()
        output.result = .copied
        let (c, _, _) = makeCoordinator(output: output)
        // Long enough that the hint would still be up without the press.
        c.copiedDisplayDuration = .seconds(5)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .copied)
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        // The cancelled hint timer must not drop us back to idle.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(c.state.isRecording)
        await c.cancelRecording()
    }

    @Test func replacingTheHotkeyMonitorWhileRecordingStopsTheMicrophone() async {
        let a = FakeHotkey()
        let b = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: a)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        a.press()
        #expect(await waitUntil { c.state.isRecording })
        c.replaceHotkeyMonitor(b)
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        #expect(b.startCount == 1)
        #expect(b.lastHotkey == c.settings.hotkey)
        // The old monitor is detached; only the new one drives the machine.
        a.press()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(c.state == .idle)
        b.press()
        #expect(await waitUntil { c.state.isRecording })
        await c.cancelRecording()
    }

    @Test func replacingTheHotkeyMonitorWhileSuspendedStartsItOnResume() async {
        let a = FakeHotkey()
        let b = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: a)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        c.isHotkeySuspended = true
        c.replaceHotkeyMonitor(b)
        #expect(b.startCount == 0)
        c.isHotkeySuspended = false
        #expect(b.startCount == 1)
        b.press()
        #expect(await waitUntil { c.state.isRecording })
        await c.cancelRecording()
    }

    @Test func outputFailureSurfacesErrorThenRecovers() async {
        let output = FakeOutput()
        output.shouldFail = true
        let (c, _, _) = makeCoordinator(output: output)
        c.errorDisplayDuration = .milliseconds(50)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .error(message: "paste failed"))
        #expect(c.lastError == "paste failed")
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func releaseWithoutPressIsNoop() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 0)
        #expect(output.inserted.isEmpty)
    }

    @Test func cancelRecordingDropsAudio() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        await c.cancelRecording()
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func disabledProcessorIsSkipped() async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.dictionary = [DictionaryEntry(from: "hello", to: "goodbye")]
        settings.setProcessor(DictionaryReplacer.processorID, enabled: false)
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["hello world"])
    }

    @Test func pressDuringTranscriptionIsDropped() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        // A second press while transcribing must not start the mic again.
        await c.hotkeyPressed()
        #expect(c.state == .transcribing)
        await c.inFlight?.value
        #expect(await capture.startCount == 1)
        #expect(output.inserted.count == 1)
    }

    @Test func hotkeyChangeWhileRecordingStopsTheMicrophone() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.settings.hotkey = .rightOption
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func engineChangeWhileRecordingUsesTheEngineThatRecorded() async {
        var registry = EngineRegistry([
            .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") { EchoEngine(text: "one", delay: .milliseconds(5)) }
        ])
        registry.register(.init(id: EngineID("two"), displayName: "Two", detail: "") { EchoEngine(text: "two", delay: .milliseconds(500)) })
        let output = FakeOutput()
        let capture = FakeCapture()
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let c = DictationCoordinator(
            settings: settings, registry: registry, capture: capture, output: output,
            hotkeyMonitor: FakeHotkey(), makePipeline: { _ in ProcessorPipeline([]) })
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.settings.engineID = EngineID("two")
        c.hotkeyReleased()
        await c.inFlight?.value
        // The dictation goes to the engine that was ready at release, not
        // the one the settings switched to mid-recording.
        #expect(output.inserted == ["one"])
        // The cycle ends in a terminal state; "two" may still be loading.
        #expect(c.state == .unavailable(reason: "Loading model") || c.state == .idle)
        #expect(await waitUntil { c.engineStatus == .ready })
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func engineChangeWhileRecordingKeepsTheCycleAlive() async {
        var registry = EngineRegistry([
            .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") { EchoEngine(text: "one", delay: .milliseconds(5)) }
        ])
        registry.register(.init(id: EngineID("two"), displayName: "Two", detail: "") { EchoEngine(text: "two", delay: .milliseconds(5)) })
        let output = FakeOutput()
        let capture = FakeCapture()
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let c = DictationCoordinator(
            settings: settings, registry: registry, capture: capture, output: output,
            hotkeyMonitor: FakeHotkey(), makePipeline: { _ in ProcessorPipeline([]) })
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.settings.engineID = EngineID("two")
        // Still recording: the switch must not clobber the state.
        #expect(c.state.isRecording)
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(await capture.stopCount == 1)
        // The new engine may or may not be loaded by the time we transcribe; either
        // way the cycle ends in a terminal state and the mic is off.
        #expect(await waitUntil { c.state == .idle || !c.state.isBusy })
        #expect(await waitUntil { c.engineStatus == .ready })
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func maximumDurationReleasesAutomatically() async {
        let (c, output, capture) = makeCoordinator()
        c.maximumDuration = .milliseconds(60)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(await waitUntil { c.state == .transcribing || c.state == .idle })
        #expect(await waitUntil { c.inFlight != nil })
        await c.inFlight?.value
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [false])
    }

    @Test func submittedReleaseIsPassedToTheOutput() async {
        let (c, output, _) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased(submit: true)
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [true])
    }

    @Test func shortTapWithSubmitInsertsNothing() async {
        let (c, output, capture) = makeCoordinator()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased(submit: true)
        await c.inFlight?.value
        #expect(output.inserted.isEmpty)
        #expect(output.submitted.isEmpty)
    }

    @Test func eventStreamReleaseCarriesSubmitFlag() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(hotkeyMonitor: hotkey)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        hotkey.press()
        #expect(await waitUntil { c.state.isRecording })
        hotkey.release(submit: true)
        #expect(await waitUntil { c.inFlight != nil })
        await c.inFlight?.value
        #expect(output.submitted == [true])
        #expect(output.inserted.count == 1)
    }

    @Test func insertedEventCarriesCycleTiming() async {
        final class EventRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _events: [DictationCoordinator.Event] = []
            var events: [DictationCoordinator.Event] { lock.withLock { _events } }
            func append(_ e: DictationCoordinator.Event) { lock.withLock { _events.append(e) } }
        }
        let recorder = EventRecorder()
        let output = FakeOutput()
        let registry = EngineRegistry([
            .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
                EchoEngine(text: "hello world", delay: .milliseconds(50))
            }
        ])
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let capture = FakeCapture()
        let timed = DictationCoordinator(
            settings: settings, registry: registry, capture: capture, output: output,
            hotkeyMonitor: FakeHotkey(), makePipeline: { _ in ProcessorPipeline([]) },
            onEvent: { recorder.append($0) })
        timed.start()
        #expect(await waitUntil { timed.state == .idle })
        await timed.hotkeyPressed()
        timed.hotkeyReleased()
        await timed.inFlight?.value
        guard case .inserted(_, let timing) = recorder.events.last else {
            Issue.record("expected an inserted event, got \(String(describing: recorder.events.last))")
            return
        }
        #expect(timing.engine >= .milliseconds(50))
        #expect(output.inserted == ["hello world"])
    }

    @Test func engineLoadFailureShowsTheEngineMessage() async {
        let registry = EngineRegistry([
            .init(id: EngineID("flaky"), displayName: "Flaky", detail: "") { FlakyEngine(failures: 1) }
        ])
        let c = DictationCoordinator(
            settings: Settings(engineID: EngineID("flaky")), registry: registry,
            capture: FakeCapture(), output: FakeOutput(),
            hotkeyMonitor: FakeHotkey(), makePipeline: { _ in ProcessorPipeline([]) })
        c.start()
        #expect(await waitUntil { c.state == .unavailable(reason: "boom") })
        #expect(c.engineStatus == .failed(message: "boom"))
    }

    @Test func reloadAfterLoadFailureRecovers() async {
        let registry = EngineRegistry([
            .init(id: EngineID("flaky"), displayName: "Flaky", detail: "") { FlakyEngine(failures: 1) }
        ])
        let c = DictationCoordinator(
            settings: Settings(engineID: EngineID("flaky")), registry: registry,
            capture: FakeCapture(), output: FakeOutput(),
            hotkeyMonitor: FakeHotkey(), makePipeline: { _ in ProcessorPipeline([]) })
        c.start()
        #expect(await waitUntil { c.state == DictationState.unavailable(reason: "boom") })
        c.reloadEngine()
        #expect(await waitUntil { c.state == DictationState.idle })
    }

    @Test func suspendingTheHotkeyDropsTheRecording() async {
        let hotkey = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: hotkey)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.isHotkeySuspended = true
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        c.isHotkeySuspended = false
        hotkey.press()
        #expect(await waitUntil { c.state.isRecording })
    }

    @Test func dictionaryChangeAfterStartIsUsedByTheNextDictation() async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.dictionary = []
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        c.settings.dictionary = [DictionaryEntry(from: "hello", to: "bye")]
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["bye world"])
    }

    @Test func submitKeyChangeWhileRecordingStopsTheMicrophone() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.settings.submitKey = Hotkey(0x24)
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func keyDownWarmsTheEngine() async {
        let (c, output, capture, engine) = makeCountingCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        // Half a second of silence was sent to the engine while recording.
        #expect(await waitUntil { engine.calls == [8_000] })
        c.hotkeyReleased()
        await c.inFlight?.value
        // The real utterance follows the warm-up and is inserted once.
        #expect(engine.calls.count == 2)
        #expect(engine.calls.last == 16_000)
        #expect(output.inserted.count == 1)
        #expect(await capture.stopCount == 1)
    }

    @Test func theEngineKeepsWarmingWhileTheKeyIsHeld() async {
        let (c, _, _, engine) = makeCountingCoordinator()
        // A real dictation warms every two seconds; the interval is settable
        // so the test does not have to wait that long.
        c.warmupInterval = .milliseconds(10)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        // One pass at key-down is not enough for a long dictation: the chip
        // goes idle between them, and a cold pass costs far more than the rest
        // of the path together.
        #expect(await waitUntil { engine.calls.filter { $0 == 8_000 }.count >= 3 })
        c.hotkeyReleased()
        await c.inFlight?.value
        // The loop stops at release, so nothing is queued ahead of the real
        // call, and the last thing the engine saw is the utterance itself.
        let afterRelease = engine.calls.count
        #expect(engine.calls.last == 16_000)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(engine.calls.count == afterRelease)
    }

    @Test func releaseDuringWarmupStillInserts() async {
        let (c, output, _, _) = makeCountingCoordinator(engineDelay: .milliseconds(200))
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        // The warm-up discarded its result; exactly one transcript lands.
        #expect(output.inserted.count == 1)
        #expect(c.state == .idle)
    }

    @Test func keyDownPreparesTheOutput() async {
        let (c, output, _) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        #expect(await waitUntil { output.prepareCount == 1 })
        c.hotkeyReleased()
        await c.inFlight?.value
    }
}

@Suite struct SettingsStoreTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        #expect(store.load() == defaults)

        var changed = defaults
        changed.hotkey = .rightOption
        changed.submitKey = Hotkey(0x24)
        changed.dictionary = [DictionaryEntry(from: "a", to: "b")]
        try store.save(changed)
        #expect(store.load() == changed)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"engineID":"echo","dictionary":[{"id":"6E36117C-6200-4C7E-BFB8-6FA228542578","from":"a","to":"b","matchCase":false}]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.engineID == EchoEngine.engineID)
        #expect(decoded.dictionary.count == 1)
        #expect(decoded.hotkey == .rightCommand)
        #expect(decoded.submitKey == .rightOption)
        #expect(decoded.appendTrailingSpace == true)
        #expect(decoded.appearance == .system)
        #expect(decoded.overlayStyle == .compact)
        #expect(decoded.overlayGlass == true)
    }

    @Test func appearancePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        var changed = defaults
        changed.appearance = .dark
        try store.save(changed)
        #expect(store.load() == changed)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func overlayStylePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        var changed = defaults
        changed.overlayStyle = .minimal
        changed.overlayGlass = false
        try store.save(changed)
        #expect(store.load() == changed)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        _ = store.load()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("broken").path))
        try? FileManager.default.removeItem(at: dir)
    }
}
