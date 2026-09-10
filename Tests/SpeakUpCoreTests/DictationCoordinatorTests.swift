import Foundation
import Testing
@testable import SpeakUpCore

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
    var inserted: [String] { lock.withLock { _inserted } }
    var shouldFail = false

    func insert(_ text: String) async throws {
        if shouldFail { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "paste failed"]) }
        lock.withLock { _inserted.append(text) }
    }
}

final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    func start(hotkey: Hotkey) -> AsyncStream<HotkeyEvent> {
        let (stream, cont) = AsyncStream<HotkeyEvent>.makeStream()
        continuation = cont
        return stream
    }
    func stop() { continuation?.finish() }
    func press() { continuation?.yield(.pressed) }
    func release() { continuation?.yield(.released) }
}

// MARK: - Helpers

@MainActor
private func makeCoordinator(
    engineText: String = "hello world",
    settings: Settings? = nil,
    output: FakeOutput = FakeOutput(),
    capture: FakeCapture = FakeCapture()
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
        hotkeyMonitor: FakeHotkey(),
        makePipeline: { s in
            ProcessorPipeline([DictionaryReplacer(entries: s.dictionary), WhitespaceNormalizer()])
        }
    )
    return (coordinator, output, capture)
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
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
        c.settings.hotkey = .rightCommand
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
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
        changed.hotkey = .rightCommand
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
        #expect(decoded.hotkey == .rightOption)
        #expect(decoded.appendTrailingSpace == true)
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

// MARK: - Prewarm

/// Counts `prepare()` and `process()` so the tests can see when the pipeline
/// was warmed relative to the release.
actor RecordingProcessor: TextProcessor {
    nonisolated let id = "recording"
    nonisolated let displayName = "Recording"
    nonisolated let detail = ""

    private(set) var prepareCount = 0
    private(set) var processCount = 0

    func prepare() async { prepareCount += 1 }

    func process(_ text: String) async throws -> String {
        processCount += 1
        return text
    }
}

/// Polls a condition that has to hop to an actor to be read. Separate name
/// from `waitUntil` so the two closures never overload-resolve against each
/// other.
private func waitUntilAsync(
    _ timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Counts pipeline builds from the `@Sendable` factory, which runs on the main
/// actor but is typed as if it could run anywhere.
final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

@MainActor
private func makePrewarmCoordinator(
    settings: Settings? = nil,
    capture: FakeCapture = FakeCapture()
) -> (DictationCoordinator, FakeOutput, FakeCapture, RecordingProcessor, BuildCounter) {
    let registry = EngineRegistry([
        .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
            EchoEngine(text: "hello world", delay: .milliseconds(5))
        }
    ])
    let output = FakeOutput()
    let recorder = RecordingProcessor()
    let builds = BuildCounter()
    let coordinator = DictationCoordinator(
        settings: settings ?? Settings(engineID: EchoEngine.engineID),
        registry: registry,
        capture: capture,
        output: output,
        hotkeyMonitor: FakeHotkey(),
        makePipeline: { s in
            builds.increment()
            return ProcessorPipeline([DictionaryReplacer(entries: s.dictionary), recorder])
        }
    )
    return (coordinator, output, capture, recorder, builds)
}

@MainActor
@Suite struct DictationCoordinatorPrewarmTests {
    @Test func prepareIsCalledOnPressBeforeRelease() async {
        let (c, _, _, recorder, _) = makePrewarmCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })

        await c.hotkeyPressed()
        // Warm-up runs in a detached task, so poll rather than assume it is
        // already done when the press returns.
        #expect(await waitUntilAsync { await recorder.prepareCount == 1 })
        #expect(await recorder.processCount == 0)

        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(await recorder.prepareCount == 1)
        #expect(await recorder.processCount == 1)
    }

    @Test func pipelineIsBuiltOncePerCycle() async {
        let (c, _, _, recorder, builds) = makePrewarmCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(builds.count == 1)
        #expect(await recorder.prepareCount == 1)
        #expect(await recorder.processCount == 1)
    }

    @Test func cancelDiscardsPreparedPipeline() async {
        let (c, _, _, recorder, builds) = makePrewarmCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })

        await c.hotkeyPressed()
        #expect(await waitUntilAsync { await recorder.prepareCount == 1 })
        await c.cancelRecording()
        #expect(c.state == .idle)

        await c.hotkeyPressed()
        #expect(await waitUntilAsync { await recorder.prepareCount == 2 })
        c.hotkeyReleased()
        await c.inFlight?.value

        #expect(builds.count == 2)
        #expect(await recorder.prepareCount == 2)
        #expect(await recorder.processCount == 1)
    }

    @Test func settingsChangeBetweenPressAndReleaseUsesPressPipeline() async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.dictionary = [DictionaryEntry(from: "hello", to: "bye")]
        settings.appendTrailingSpace = false
        let (c, output, _, _, builds) = makePrewarmCoordinator(settings: settings)
        c.start()
        #expect(await waitUntil { c.state == .idle })

        await c.hotkeyPressed()
        // The dictionary the user had when they started speaking is the one
        // that applies to this utterance.
        c.settings.dictionary = []
        c.hotkeyReleased()
        await c.inFlight?.value

        #expect(output.inserted == ["bye world"])
        #expect(builds.count == 1)
    }

    @Test func shortTapDiscardsPreparedPipeline() async {
        let capture = FakeCapture()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        let (c, output, _, recorder, builds) = makePrewarmCoordinator(capture: capture)
        c.start()
        #expect(await waitUntil { c.state == .idle })

        await c.hotkeyPressed()
        #expect(await waitUntilAsync { await recorder.prepareCount == 1 })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(output.inserted.isEmpty)
        #expect(await recorder.processCount == 0)

        // The next press starts from scratch: new pipeline, warmed again.
        await capture.setSamples(Array(repeating: 0.1, count: 16_000))
        await c.hotkeyPressed()
        #expect(await waitUntilAsync { await recorder.prepareCount == 2 })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(builds.count == 2)
        #expect(await recorder.processCount == 1)
    }
}
