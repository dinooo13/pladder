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

        await c.hotkeyReleased()
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
        await c.hotkeyReleased()
        #expect(output.inserted == ["hello world"])
    }

    @Test func shortTapIsDiscarded() async {
        let (c, output, capture) = makeCoordinator()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        await c.hotkeyReleased()
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
        await c.hotkeyReleased()
    }

    @Test func outputFailureSurfacesErrorThenRecovers() async {
        let output = FakeOutput()
        output.shouldFail = true
        let (c, _, _) = makeCoordinator(output: output)
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyPressed()
        await c.hotkeyReleased()
        #expect(c.state == .error(message: "paste failed"))
        #expect(c.lastError == "paste failed")
        #expect(await waitUntil(.seconds(3)) { c.state == .idle })
    }

    @Test func releaseWithoutPressIsNoop() async {
        let (c, output, capture) = makeCoordinator()
        c.start()
        #expect(await waitUntil { c.state == .idle })
        await c.hotkeyReleased()
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
        await c.hotkeyReleased()
        #expect(output.inserted == ["hello world"])
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
}
