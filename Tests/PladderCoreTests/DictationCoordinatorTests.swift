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
    var inserted: [String] { lock.withLock { _inserted } }
    var submitted: [Bool] { lock.withLock { _submitted } }
    var shouldFail = false

    func insert(_ text: String, submit: Bool) async throws {
        if shouldFail { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "paste failed"]) }
        lock.withLock {
            _inserted.append(text)
            _submitted.append(submit)
        }
    }
}

final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    func start(hotkey: Hotkey, submitKey: Hotkey) -> AsyncStream<HotkeyEvent> {
        let (stream, cont) = AsyncStream<HotkeyEvent>.makeStream()
        continuation = cont
        return stream
    }
    func stop() { continuation?.finish() }
    func press() { continuation?.yield(.pressed) }
    func release(submit: Bool = false) { continuation?.yield(.released(submit: submit)) }
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
        c.settings.hotkey = .rightOption
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
