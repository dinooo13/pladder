import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

// MARK: - Fakes

/// Waits without honouring cancellation, the way a CoreML pass in flight
/// does: the coordinator cancels its loops at release, and a fake that woke
/// early would hide what the release really waits for.
func uncancellableSleep(_ duration: Duration) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + duration.timeInterval) { done.resume() }
    }
}

actor FakeCapture: AudioCapture {
    var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000)
    /// What each `drain()` hands the streaming feed. Empty by default, so the
    /// batch tests see the path they always saw.
    var drainSamples: [Float] = []
    var startCount = 0
    var stopCount = 0
    var levelContinuation: AsyncStream<Float>.Continuation?
    /// How long `stop()` takes, to widen the window a cancel leaves open.
    var stopDelay: Duration = .zero

    func start() async throws -> AsyncStream<Float> {
        startCount += 1
        let (stream, cont) = AsyncStream<Float>.makeStream()
        levelContinuation = cont
        return stream
    }

    func drain() async -> [Float] {
        drainSamples
    }

    func stop() async -> CapturedAudio {
        stopCount += 1
        levelContinuation?.finish()
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
        return CapturedAudio(samples: samplesToReturn)
    }

    func warmUp() async throws {}

    func setSamples(_ s: [Float]) { samplesToReturn = s }
    func setDrainSamples(_ s: [Float]) { drainSamples = s }
    func setStopDelay(_ d: Duration) { stopDelay = d }
    func emitLevel(_ l: Float) { levelContinuation?.yield(l) }
}

final class FakeOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: [String] = []
    private var _submitted: [Bool] = []
    private var _prepareCount = 0
    private var _flushCount = 0
    var inserted: [String] { lock.withLock { _inserted } }
    var flushCount: Int { lock.withLock { _flushCount } }
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

    func flush() async {
        lock.withLock { _flushCount += 1 }
    }
}

final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private var continuation: AsyncStream<HotkeyMonitorEvent>.Continuation?
    /// How often `start` was called, and with what, so a monitor swap can be
    /// checked from the outside.
    private(set) var startCount = 0
    private(set) var lastChords: [HotkeyRole: Hotkey] = [:]
    var lastHotkey: Hotkey? { lastChords[.dictate] }
    /// The dictate chord of every start, in order.
    private(set) var startedHotkeys: [Hotkey?] = []
    func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        startCount += 1
        lastChords = chords
        startedHotkeys.append(chords[.dictate])
        let (stream, cont) = AsyncStream<HotkeyMonitorEvent>.makeStream()
        continuation = cont
        return stream
    }
    private(set) var stopCount = 0
    func stop() {
        stopCount += 1
        continuation?.finish()
    }
    /// The keyboard's own clock. Every event is stamped with it, as the real
    /// monitors stamp theirs, and it moves on by `step` per event, so holds
    /// and the gaps the bounce rule looks at are arithmetic rather than the
    /// test sleeping. The coordinator times gestures by these instants only.
    private(set) var time = ContinuousClock.now
    var step: Duration = .milliseconds(100)
    private func stamp() -> ContinuousClock.Instant {
        time += step
        return time
    }
    func press(_ role: HotkeyRole = .dictate) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .pressed, instant: stamp()))
    }
    func release(_ role: HotkeyRole = .dictate, submit: Bool = false) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .released(submit: submit), instant: stamp()))
    }
    func cancel(_ role: HotkeyRole = .dictate) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .cancelled, instant: stamp()))
    }
    /// Any event, for a test that stamps its own instants; later events
    /// continue from it.
    func send(_ event: HotkeyMonitorEvent) {
        if let instant = event.instant, instant > time { time = instant }
        continuation?.yield(event)
    }
    /// Every `setCancelKeyEnabled` call, in order.
    private(set) var cancelKeyEnabled: [Bool] = []
    func setCancelKeyEnabled(_ enabled: Bool) { cancelKeyEnabled.append(enabled) }
    func escape() { continuation?.yield(HotkeyMonitorEvent(.escape)) }
}

/// Stands in for the on-device model: records what it was asked, answers
/// `result` after `delay`.
final class FakeRefiner: TranscriptRefiner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _prepareCount = 0
    private let result: String?
    private let delay: Duration
    var calls: [String] { lock.withLock { _calls } }
    var prepareCount: Int { lock.withLock { _prepareCount } }

    init(result: String? = "polished", delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func prepare() async { lock.withLock { _prepareCount += 1 } }

    func refine(_ text: String) async -> String? {
        lock.withLock { _calls.append(text) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
}

/// Records the two calls the coordinator makes and the session each names.
/// The real controller's ordering rules are tested on their own; what
/// matters here is that both ends are called, from every path that ends a
/// recording, and that an end names the session its start named.
final class FakeOutputMuter: OutputMuter, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [Int] = []
    private var _ended: [Int] = []
    var startedSessions: [Int] { lock.withLock { _started } }
    var endedSessions: [Int] { lock.withLock { _ended } }
    var startedCount: Int { startedSessions.count }
    var endedCount: Int { endedSessions.count }

    func recordingStarted(session: Int) async { lock.withLock { _started.append(session) } }
    func recordingEnded(session: Int) async { lock.withLock { _ended.append(session) } }
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
            status = .failed(.loadFailed(detail: "boom"))
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
    private let recorder = Recorder<Int>()
    private let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }
    nonisolated var calls: [Int] { recorder.all }

    func load() async throws { status = .ready }
    func transcribe(_ samples: [Float]) async throws -> Transcript {
        recorder.append(samples.count)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return Transcript(text: "counted", audioDuration: Double(samples.count) / CapturedAudio.sampleRate, processingTime: 0, engineID: id)
    }
    func unload() { status = .unloaded }
}

/// A streaming engine that counts everything the coordinator asks of it, so a
/// test can tell a live loop from a warm one. `livePass` answers
/// "partial <n>"; only `endUtterance` produces the text that gets inserted,
/// and `transcribe` answers "whole", so a test can tell the two paths apart.
/// Every call is also logged by name, in order.
actor FakeStreamingEngine: StreamingTranscriptionEngine {
    static let engineID = EngineID("fake-streaming")
    nonisolated let id: EngineID
    nonisolated let displayName = "Fake streaming"
    private(set) var status: EngineStatus = .unloaded

    private let counters = StreamingCounters()
    private let livePassDelay: Duration
    private let feedDelay: Duration
    private let beginFails: Bool

    init(
        id: EngineID = FakeStreamingEngine.engineID,
        livePassDelay: Duration = .zero,
        feedDelay: Duration = .zero,
        beginFails: Bool = false
    ) {
        self.id = id
        self.livePassDelay = livePassDelay
        self.feedDelay = feedDelay
        self.beginFails = beginFails
    }

    nonisolated var feedCounts: [Int] { counters.feedCounts }
    nonisolated var livePassCount: Int { counters.livePassCount }
    nonisolated var warmPassCount: Int { counters.warmPassCount }
    nonisolated var endCount: Int { counters.endCount }
    nonisolated var log: [String] { counters.log }
    /// True while a `feed` is waiting out its delay.
    nonisolated var isFeeding: Bool { counters.isFeeding }

    struct BeginFailed: Error {}

    func load() async throws { status = .ready }
    func unload() { status = .unloaded }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        counters.record("transcribe")
        return Transcript(text: "whole", audioDuration: 0, processingTime: 0, engineID: id)
    }

    func beginUtterance() async throws {
        counters.record("begin")
        if beginFails { throw BeginFailed() }
    }

    func feed(_ samples: [Float]) async {
        counters.fed(samples.count)
        if feedDelay > .zero {
            counters.setFeeding(true)
            await uncancellableSleep(feedDelay)
            counters.setFeeding(false)
        }
        counters.record("fed")
    }

    func endUtterance(_ tail: [Float]) async throws -> Transcript {
        counters.ended()
        return Transcript(text: "final", audioDuration: 0, processingTime: 0, engineID: id)
    }

    func abandonUtterance() async { counters.record("abandon") }

    func warmPass() async { counters.warmed() }

    func livePass() async -> String? {
        let n = counters.lived()
        // Counted before the delay, so a test can catch a pass in flight.
        if livePassDelay > .zero { await uncancellableSleep(livePassDelay) }
        return "partial \(n)"
    }
}

/// Lock-protected so the counters can be read synchronously from a `waitUntil`.
private final class StreamingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var _feedCounts: [Int] = []
    private var _livePassCount = 0
    private var _warmPassCount = 0
    private var _endCount = 0
    private var _log: [String] = []
    private var _isFeeding = false
    var feedCounts: [Int] { lock.withLock { _feedCounts } }
    var livePassCount: Int { lock.withLock { _livePassCount } }
    var warmPassCount: Int { lock.withLock { _warmPassCount } }
    var endCount: Int { lock.withLock { _endCount } }
    var log: [String] { lock.withLock { _log } }
    var isFeeding: Bool { lock.withLock { _isFeeding } }
    func fed(_ count: Int) { lock.withLock { _feedCounts.append(count); _log.append("feed") } }
    func warmed() { lock.withLock { _warmPassCount += 1 } }
    func ended() { lock.withLock { _endCount += 1; _log.append("end") } }
    func lived() -> Int { lock.withLock { _livePassCount += 1; _log.append("live"); return _livePassCount } }
    func record(_ name: String) { lock.withLock { _log.append(name) } }
    func setFeeding(_ feeding: Bool) { lock.withLock { _isFeeding = feeding } }
}

// MARK: - Helpers

@MainActor
func makeCoordinator(
    engineText: String = "hello world",
    engines: [EngineRegistry.Entry]? = nil,
    settings: DictationSettings? = nil,
    output: FakeOutput = FakeOutput(),
    capture: FakeCapture = FakeCapture(),
    hotkeyMonitor: FakeHotkey? = nil,
    outputMuter: (any OutputMuter)? = nil,
    refiner: (any TranscriptRefiner)? = nil,
    makePipeline: @escaping @Sendable (DictationSettings) -> ProcessorPipeline = { s in
        ProcessorPipeline([DictionaryReplacer(entries: s.dictionary), WhitespaceNormalizer()])
    },
    clock: any Clock<Duration> = ContinuousClock(),
    events: EventLog? = nil
) -> (DictationCoordinator, FakeOutput, FakeCapture) {
    let engines = engines ?? [.serving(EchoEngine(text: engineText, delay: .milliseconds(5)))]
    let coordinator = DictationCoordinator(
        settings: settings ?? DictationSettings(engineID: engines[0].id),
        registry: EngineRegistry(engines),
        capture: capture,
        output: output,
        outputMuter: outputMuter,
        refiner: refiner,
        hotkeyMonitor: hotkeyMonitor ?? FakeHotkey(),
        makePipeline: makePipeline,
        clock: clock,
        onEvent: { event in events?.append(event) }
    )
    return (coordinator, output, capture)
}

extension EngineRegistry.Entry {
    static func serving(_ engine: any TranscriptionEngine) -> Self {
        .init(id: engine.id, displayName: engine.displayName, detail: "") { engine }
    }
}

/// Builds a coordinator around a CountingEngine.
@MainActor
func makeCountingCoordinator(
    engineDelay: Duration = .zero,
    clock: any Clock<Duration> = ContinuousClock()
) -> (DictationCoordinator, FakeOutput, FakeCapture, CountingEngine) {
    let engine = CountingEngine(delay: engineDelay)
    var settings = DictationSettings(engineID: CountingEngine.engineID)
    settings.appendTrailingSpace = false
    let (coordinator, output, capture) = makeCoordinator(engines: [.serving(engine)], settings: settings, clock: clock)
    return (coordinator, output, capture, engine)
}

/// Builds a coordinator around a streaming engine, with the capture handing
/// the feed loop half a second of audio per drain.
@MainActor
func makeStreamingCoordinator(
    style: OverlayStyle,
    livePassDelay: Duration = .zero,
    engine: FakeStreamingEngine? = nil,
    events: EventLog? = nil
) async -> (DictationCoordinator, FakeOutput, FakeCapture, FakeStreamingEngine) {
    let capture = FakeCapture()
    await capture.setDrainSamples(Array(repeating: 0.1, count: 8_000))
    let engine = engine ?? FakeStreamingEngine(livePassDelay: livePassDelay)
    var settings = DictationSettings(engineID: engine.id)
    settings.appendTrailingSpace = false
    settings.liveTranscript = style == .liveTranscript
    let (coordinator, output, _) = makeCoordinator(
        engines: [.serving(engine)], settings: settings, capture: capture, makePipeline: { _ in ProcessorPipeline([]) },
        events: events)
    // Every loop on a short fuse so the tests do not have to wait seconds.
    coordinator.livePassInterval = .milliseconds(10)
    coordinator.warmupInterval = .milliseconds(10)
    coordinator.feedInterval = .milliseconds(10)
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

/// `waitUntil` for a condition that has to ask an actor: a dropped
/// recording is idle at once, and its microphone stops on a task after.
func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension DictationCoordinator {
    func startIdle(sourceLocation: SourceLocation = #_sourceLocation) async {
        start()
        #expect(await waitUntil { self.state == .idle }, sourceLocation: sourceLocation)
    }

    func dictate(submit: Bool = false) async {
        await hotkeyPressed()
        hotkeyReleased(submit: submit)
        await inFlight?.value
    }

    func press(_ hotkey: FakeHotkey, sourceLocation: SourceLocation = #_sourceLocation) async {
        hotkey.press()
        #expect(await waitUntil { self.state.isRecording }, sourceLocation: sourceLocation)
    }

    func cycleFinished(sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await waitUntil { self.inFlight != nil }, sourceLocation: sourceLocation)
        await inFlight?.value
    }
}

/// Records the coordinator's events by name, for assertions about order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    private var _events: [DictationCoordinator.Event] = []
    var names: [String] { lock.withLock { _names } }
    var events: [DictationCoordinator.Event] { lock.withLock { _events } }

    /// The last `inserted` event, if there was one.
    var lastInsertion: DictationCoordinator.Insertion? {
        for event in events.reversed() {
            if case .inserted(let insertion) = event { return insertion }
        }
        return nil
    }

    func append(_ event: DictationCoordinator.Event) {
        let name: String
        switch event {
        case .recordingStarted: name = "recordingStarted"
        case .recordingStopped: name = "recordingStopped"
        case .inserted: name = "inserted"
        case .failed: name = "failed"
        case .keyboardBounceObserved: name = "keyboardBounceObserved"
        case .recordingDiscarded: name = "recordingDiscarded"
        }
        lock.withLock {
            _names.append(name)
            _events.append(event)
        }
    }
}

// MARK: - Tests

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DictationCoordinatorTests {
    @Test func startsUnavailableThenIdleWhenEngineReady() async {
        let (c, _, _) = makeCoordinator()
        #expect(c.state == .unavailable(.starting))
        await c.startIdle()
        #expect(c.engineStatus == .ready)
    }

    @Test func ignoresPressWhileEngineNotReady() async {
        let (c, _, capture) = makeCoordinator()
        await c.hotkeyPressed()
        #expect(c.state == .unavailable(.starting))
        #expect(await capture.startCount == 0)
    }

    @Test func fullDictationCycleInsertsProcessedText() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.dictionary = [DictionaryEntry(from: "hello world", to: "Hello, World!")]
        let (c, output, capture) = makeCoordinator(settings: settings)
        await c.startIdle()

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
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        await c.startIdle()
        await c.dictate()
        #expect(output.inserted == ["hello world"])
    }

    @Test func shortTapIsDiscarded() async {
        let (c, output, capture) = makeCoordinator()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        await c.startIdle()
        await c.dictate()
        #expect(c.state == .idle)
        #expect(output.inserted.isEmpty)
    }

    @Test func levelUpdatesFlowIntoState() async {
        let (c, _, capture) = makeCoordinator()
        await c.startIdle()
        await c.hotkeyPressed()
        await capture.emitLevel(0.7)
        #expect(await waitUntil { c.inputLevel == 0.7 })
        c.hotkeyReleased()
        await c.inFlight?.value
    }

    @Test func cancelledEventDropsTheRecordingSilently() async {
        let hotkey = FakeHotkey()
        let events = EventLog()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: hotkey, events: events)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.cancel()
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        // No `recordingStopped`: nothing plays the stop sound and nothing
        // starts the release-to-paste measurement for a dictation that was
        // never one.
        #expect(events.names == ["recordingStarted"])
    }

    @Test func replacingTheHotkeyMonitorWhileRecordingStopsTheMicrophone() async {
        let a = FakeHotkey()
        let b = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: a)
        await c.startIdle()
        await c.press(a)
        c.replaceHotkeyMonitor(b)
        #expect(await waitUntil { c.state == .idle })
        #expect(await eventually { await capture.stopCount == 1 })
        #expect(output.inserted.isEmpty)
        #expect(b.startCount == 1)
        #expect(b.lastHotkey == c.settings.hotkey)
        // The old monitor is stopped, so its stream is over; only the new one
        // drives the machine.
        #expect(a.stopCount >= 1)
        await c.press(b)
        await c.cancelRecording()
    }

    @Test func replacingTheHotkeyMonitorWhileSuspendedStartsItOnResume() async {
        let a = FakeHotkey()
        let b = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: a)
        await c.startIdle()
        c.isHotkeySuspended = true
        c.replaceHotkeyMonitor(b)
        #expect(b.startCount == 0)
        c.isHotkeySuspended = false
        #expect(b.startCount == 1)
        await c.press(b)
        await c.cancelRecording()
    }

    // MARK: Stand-in chord

    /// An override chord; the coordinator does not care which, it just starts
    /// the monitor with whatever the app hands it.
    private static let standIn = Hotkey(0x3B, 0x38, 0x31)

    @Test func hotkeyOverrideIsWhatTheMonitorStarts() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        // Set before `start()`, the way the app does it: one registration.
        c.hotkeyOverride = Self.standIn
        #expect(fake.startCount == 0)
        await c.startIdle()
        #expect(fake.startCount == 1)
        #expect(fake.lastHotkey == Self.standIn)
        #expect(c.settings.hotkey == .optionSpace)
    }

    @Test func changingTheOverrideWhileRecordingStopsTheMicrophone() async {
        let fake = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: fake)
        await c.startIdle()
        await c.press(fake)
        c.hotkeyOverride = Self.standIn
        #expect(await waitUntil { c.state == .idle })
        #expect(await eventually { await capture.stopCount == 1 })
        #expect(output.inserted.isEmpty)
        #expect(fake.startCount == 2)
        #expect(fake.lastHotkey == Self.standIn)
    }

    @Test func clearingTheOverrideReturnsToTheStoredChord() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        c.hotkeyOverride = Self.standIn
        await c.startIdle()
        // What granting Accessibility does.
        c.hotkeyOverride = nil
        #expect(fake.startCount == 2)
        #expect(fake.lastHotkey == c.settings.hotkey)
        await c.press(fake)
        await c.cancelRecording()
    }

    @Test func unchangedOverrideDoesNotRestartTheMonitor() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        c.hotkeyOverride = Self.standIn
        await c.startIdle()
        // The app recomputes the stand-in on every permission flip; the same
        // answer must not tear the registration down and build it again.
        c.hotkeyOverride = Self.standIn
        #expect(fake.startCount == 1)
    }

    // Before: the app set the chord, which restarted the monitor with the
    // old stand-in, then the stand-in, which restarted it again. Without
    // Accessibility the first restart handed Carbon a modifier-only chord it
    // cannot register.
    @Test func aChordAndItsStandInChangeInOneRestart() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        await c.startIdle()
        var settings = c.settings
        settings.hotkey = .rightOption
        c.update(settings, hotkeyOverride: Self.standIn)
        #expect(fake.startedHotkeys == [.optionSpace, Self.standIn])

        // And back: a chord Carbon can register clears the stand-in, again
        // in one restart, never with the modifier-only chord.
        settings.hotkey = Hotkey(0x3B, 0x02)
        c.update(settings, hotkeyOverride: nil)
        #expect(fake.startedHotkeys == [.optionSpace, Self.standIn, Hotkey(0x3B, 0x02)])

        // Nothing that concerns the monitor: no restart.
        settings.appendTrailingSpace.toggle()
        c.update(settings, hotkeyOverride: nil)
        #expect(fake.startCount == 3)
    }

    // Before: the recording was dropped from a task while the new monitor
    // started at once, so a press on the new stream that came first found
    // `.recording` still set and was refused.
    @Test func aPressRightAfterAMonitorSwapStartsADictation() async {
        let a = FakeHotkey()
        let b = FakeHotkey()
        let (c, _, capture) = makeCoordinator(hotkeyMonitor: a)
        await capture.setStopDelay(.milliseconds(50))
        await c.startIdle()
        await c.press(a)
        c.replaceHotkeyMonitor(b)
        // Ended before the new monitor can deliver anything.
        #expect(c.state == .idle)
        b.press()
        // The press waited for the microphone to stop, then started it again.
        #expect(await waitUntil { c.handledHotkeyEvents == 2 })
        #expect(c.state.isRecording)
        #expect(await capture.startCount == 2)
        #expect(await capture.stopCount == 1)
        await c.cancelRecording()
    }

    @Test func overrideWhileSuspendedStartsOnResume() async {
        let fake = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: fake)
        await c.startIdle()
        c.isHotkeySuspended = true
        c.hotkeyOverride = Self.standIn
        #expect(fake.startCount == 1)
        c.isHotkeySuspended = false
        #expect(fake.startCount == 2)
        #expect(fake.lastHotkey == Self.standIn)
    }

    @Test func releaseWithoutPressIsNoop() async {
        let (c, output, capture) = makeCoordinator()
        await c.startIdle()
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 0)
        #expect(output.inserted.isEmpty)
    }

    @Test func cancelRecordingDropsAudio() async {
        let (c, output, capture) = makeCoordinator()
        await c.startIdle()
        await c.hotkeyPressed()
        await c.cancelRecording()
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func disabledProcessorIsSkipped() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.dictionary = [DictionaryEntry(from: "hello", to: "goodbye")]
        settings.disabledProcessors.insert(DictionaryReplacer.processorID)
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        await c.startIdle()
        await c.dictate()
        #expect(output.inserted == ["hello world"])
    }

    @Test func pressDuringTranscriptionIsDropped() async {
        let (c, output, capture) = makeCoordinator()
        await c.startIdle()
        await c.hotkeyPressed()
        c.hotkeyReleased()
        // A second press while transcribing must not start the mic again.
        await c.hotkeyPressed()
        #expect(c.state == .transcribing)
        await c.inFlight?.value
        #expect(await capture.startCount == 1)
        #expect(output.inserted.count == 1)
    }

    @Test func aChordChangeWhileRecordingStopsTheMicrophone() async {
        let changes: [(inout DictationSettings) -> Void] = [
            { $0.hotkey = .rightOption },
            { $0.submitKey = Hotkey(0x24) },
            { $0.toggleHotkey = Hotkey(0x3B, 0x02) },
        ]
        for change in changes {
            let (c, output, capture) = makeCoordinator()
            await c.startIdle()
            await c.hotkeyPressed()
            #expect(c.state.isRecording)
            change(&c.settings)
            #expect(await waitUntil { c.state == .idle })
            #expect(await eventually { await capture.stopCount == 1 })
            #expect(output.inserted.isEmpty)
        }
    }

    @Test func engineChangeWhileRecordingUsesTheEngineThatRecorded() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let (c, output, capture) = makeCoordinator(
            engines: [
                .serving(EchoEngine(text: "one", delay: .milliseconds(5))),
                .init(id: EngineID("two"), displayName: "Two", detail: "") { EchoEngine(text: "two", delay: .milliseconds(500)) },
            ],
            settings: settings)
        await c.startIdle()
        await c.hotkeyPressed()
        c.settings.engineID = EngineID("two")
        // Still recording: the switch must not clobber the state.
        #expect(c.state.isRecording)
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(await capture.stopCount == 1)
        // The dictation goes to the engine that was ready at release, not
        // the one the settings switched to mid-recording.
        #expect(output.inserted == ["one"])
        // The cycle ends in a terminal state; "two" may still be loading.
        #expect(c.state == .unavailable(.loadingModel) || c.state == .idle)
        #expect(await waitUntil { c.engineStatus == .ready })
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func submittedReleaseIsPassedToTheOutput() async {
        let (c, output, _) = makeCoordinator()
        await c.startIdle()
        await c.dictate(submit: true)
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [true])
    }

    @Test func shortTapWithSubmitInsertsNothing() async {
        let (c, output, capture) = makeCoordinator()
        await capture.setSamples(Array(repeating: 0, count: 1_600)) // 0.1 s
        await c.startIdle()
        await c.dictate(submit: true)
        #expect(output.inserted.isEmpty)
        #expect(output.submitted.isEmpty)
    }

    @Test func eventStreamReleaseCarriesSubmitFlag() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(hotkeyMonitor: hotkey)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release(submit: true)
        await c.cycleFinished()
        #expect(output.submitted == [true])
        #expect(output.inserted.count == 1)
    }

    @Test func insertedEventCarriesCycleTiming() async throws {
        let events = EventLog()
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(
            engines: [.serving(EchoEngine(text: "hello world", delay: .milliseconds(50)))],
            settings: settings, events: events)
        await c.startIdle()
        await c.dictate()
        let timing = try #require(events.lastInsertion?.timing)
        #expect(timing.engine >= .milliseconds(50))
        #expect(timing.polish == nil)
        #expect(output.inserted == ["hello world"])
    }

    @Test func engineLoadFailureShowsTheEngineMessageAndReloadRecovers() async {
        let (c, _, _) = makeCoordinator(engines: [.serving(FlakyEngine(failures: 1))])
        c.start()
        #expect(await waitUntil { c.state == .unavailable(.engineFailed(.loadFailed(detail: "boom"))) })
        #expect(c.engineStatus == .failed(.loadFailed(detail: "boom")))
        c.reloadEngine()
        #expect(await waitUntil { c.state == .idle })
    }

    @Test func suspendingTheHotkeyDropsTheRecording() async {
        let hotkey = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: hotkey)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(c.state.isRecording)
        c.isHotkeySuspended = true
        #expect(await waitUntil { c.state == .idle })
        #expect(await eventually { await capture.stopCount == 1 })
        #expect(output.inserted.isEmpty)
        c.isHotkeySuspended = false
        await c.press(hotkey)
    }

    @Test func dictionaryChangeAfterStartIsUsedByTheNextDictation() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.dictionary = []
        settings.appendTrailingSpace = false
        let (c, output, _) = makeCoordinator(settings: settings)
        await c.startIdle()
        c.settings.dictionary = [DictionaryEntry(from: "hello", to: "bye")]
        await c.dictate()
        #expect(output.inserted == ["bye world"])
    }

    @Test func keyDownWarmsTheEngine() async {
        let (c, output, capture, engine) = makeCountingCoordinator()
        await c.startIdle()
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

    @Test func releaseDuringWarmupStillInserts() async {
        let (c, output, _, _) = makeCountingCoordinator(engineDelay: .milliseconds(200))
        await c.startIdle()
        await c.dictate()
        // The warm-up discarded its result; exactly one transcript lands.
        #expect(output.inserted.count == 1)
        #expect(c.state == .idle)
    }

    @Test func keyDownPreparesTheOutput() async {
        let (c, output, _) = makeCoordinator()
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { output.prepareCount == 1 })
        c.hotkeyReleased()
        await c.inFlight?.value
    }

    // MARK: Live transcript

    @Test func liveStylePublishesPartialsAndInsertsOnce() async {
        let (c, output, _, engine) = await makeStreamingCoordinator(style: .liveTranscript)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.livePassCount >= 3 })
        #expect(c.partialTranscript?.hasPrefix("partial") == true)
        // The live pass is the warm pass; running both would put two callers
        // on the Neural Engine at once.
        #expect(engine.warmPassCount == 0)
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["final"])
        #expect(engine.endCount == 1)
        #expect(c.partialTranscript == nil)
    }

    @Test func partialTranscriptNeverReachesTheOutput() async {
        let (c, output, _, engine) = await makeStreamingCoordinator(style: .liveTranscript)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.livePassCount >= 2 })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted == ["final"])
        #expect(!output.inserted.contains { $0.contains("partial") })
        #expect(c.lastTranscript?.text == "final")
    }

    @Test func releaseDuringLivePassStillInsertsExactlyOnce() async {
        let (c, output, _, engine) = await makeStreamingCoordinator(
            style: .liveTranscript, livePassDelay: .milliseconds(200))
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { engine.livePassCount == 1 })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
        #expect(c.state == .idle)
        // The release waited for the pass that was in flight; its text
        // belongs to a recording that has already been pasted, so it never
        // reached the screen.
        #expect(c.partialTranscript == nil)
    }

    @Test func livePassesDoNotRunForOtherStyles() async {
        for style in [OverlayStyle.compact, .minimal, .menuBar] {
            let (c, output, _, engine) = await makeStreamingCoordinator(style: style)
            await c.startIdle()
            await c.hotkeyPressed()
            #expect(await waitUntil { engine.warmPassCount >= 1 })
            #expect(engine.livePassCount == 0)
            #expect(c.partialTranscript == nil)
            c.hotkeyReleased()
            await c.inFlight?.value
            #expect(engine.livePassCount == 0)
            #expect(output.inserted == ["final"])
        }
    }

    @Test func cancelRecordingClearsThePartialTranscript() async {
        let (c, output, _, engine) = await makeStreamingCoordinator(style: .liveTranscript)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { c.partialTranscript != nil })
        await c.cancelRecording()
        #expect(c.partialTranscript == nil)
        #expect(c.state == .idle)
        #expect(output.inserted.isEmpty)
        #expect(engine.endCount == 0)
    }

    // MARK: Output mute

    @Test func mutesAndRestoresTheOutputDeviceWhenTheSettingIsOn() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.muteOutputWhileDictating = true
        let muter = FakeOutputMuter()
        let (c, _, _) = makeCoordinator(settings: settings, outputMuter: muter)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { muter.startedCount == 1 })
        c.hotkeyReleased()
        await c.inFlight?.value
        #expect(await waitUntil { muter.endedCount == 1 })
        #expect(muter.startedCount == 1)
    }

    /// The setting gates the mute, never the restore: turning it off while the
    /// key is held must not strand a muted device.
    @Test func withTheSettingOffNothingIsMutedButTheRestoreStillRuns() async {
        let muter = FakeOutputMuter()
        let (c, _, _) = makeCoordinator(outputMuter: muter)
        await c.startIdle()
        await c.dictate()
        #expect(await waitUntil { muter.endedCount == 1 })
        #expect(muter.startedCount == 0)
    }

    @Test func everyDiscardRestoresTheOutputDevice() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.muteOutputWhileDictating = true
        let discards: [(DictationCoordinator, FakeHotkey) async -> Void] = [
            { c, _ in await c.cancelRecording() },
            { c, _ in await c.escapePressed() },
            { _, hotkey in hotkey.cancel() },
        ]
        for discard in discards {
            let hotkey = FakeHotkey()
            let muter = FakeOutputMuter()
            let (c, _, _) = makeCoordinator(settings: settings, hotkeyMonitor: hotkey, outputMuter: muter)
            await c.startIdle()
            await c.press(hotkey)
            await discard(c, hotkey)
            #expect(await waitUntil { muter.endedCount == 1 })
        }
    }

}

// MARK: - Polish toggle

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PolishToggleTests {
    /// Long enough to clear `minimumPolishWords`.
    private static let sentence = "send it on Friday please"

    private static func settings(polish: Bool = true) -> DictationSettings {
        var s = DictationSettings(engineID: EchoEngine.engineID)
        s.polishDictations = polish
        return s
    }

    @Test func polishRoutesThroughTheRefiner() async {
        let refiner = FakeRefiner()
        let events = EventLog()
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(
            engineText: Self.sentence, settings: Self.settings(),
            hotkeyMonitor: hotkey, refiner: refiner, events: events)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release()
        await c.cycleFinished()
        #expect(output.inserted == ["polished "])
        #expect(refiner.calls == [Self.sentence])
        #expect(c.lastTranscript?.text == "polished")
        #expect(events.lastInsertion?.timing.polish != nil)
    }

    @Test func normalHotkeyNeverCallsTheRefiner() async {
        let refiner = FakeRefiner()
        let events = EventLog()
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(
            engineText: Self.sentence, settings: Self.settings(polish: false),
            hotkeyMonitor: hotkey, refiner: refiner, events: events)
        await c.startIdle()
        await c.press(hotkey)
        #expect(!c.willPolish)
        hotkey.release()
        await c.cycleFinished()
        #expect(output.inserted == [Self.sentence + " "])
        #expect(refiner.calls.isEmpty)
        #expect(refiner.prepareCount == 0)
        #expect(events.lastInsertion != nil)
        #expect(events.lastInsertion?.timing.polish == nil)
    }

    @Test func blankTranscriptSkipsTheRefiner() async {
        let refiner = FakeRefiner()
        let (c, output, _) = makeCoordinator(engineText: "", settings: Self.settings(), refiner: refiner)
        await c.startIdle()
        await c.dictate()
        #expect(output.inserted.isEmpty)
        #expect(refiner.calls.isEmpty)
        #expect(c.state == .idle)
    }

    @Test func shortTranscriptSkipsTheRefiner() async {
        let refiner = FakeRefiner()
        let events = EventLog()
        let (c, output, _) = makeCoordinator(
            engineText: "one two three", settings: Self.settings(), refiner: refiner, events: events)
        await c.startIdle()
        await c.dictate()
        #expect(output.inserted == ["one two three "])
        #expect(refiner.calls.isEmpty)
        #expect(events.lastInsertion?.timing.polish == .zero)
    }

    @Test func fourWordsAreRefined() async {
        let refiner = FakeRefiner()
        let (c, output, _) = makeCoordinator(
            engineText: "one two three four", settings: Self.settings(), refiner: refiner)
        await c.startIdle()
        await c.dictate()
        #expect(refiner.calls == ["one two three four"])
        #expect(output.inserted == ["polished "])
    }

    @Test func refinerReturningNilPastesThePlainText() async {
        // What an unavailable, refusing or timed-out model looks like here.
        let refiner = FakeRefiner(result: nil)
        let events = EventLog()
        let (c, output, _) = makeCoordinator(
            engineText: Self.sentence, settings: Self.settings(), refiner: refiner, events: events)
        await c.startIdle()
        await c.dictate()
        #expect(refiner.calls == [Self.sentence])
        #expect(output.inserted == [Self.sentence + " "])
        #expect(c.lastTranscript?.text == Self.sentence)
        guard case .inserted = events.events.last else {
            Issue.record("expected an inserted event, got \(String(describing: events.events.last))")
            return
        }
        #expect(c.state == .idle)
    }

    @Test func withoutARefinerPolishIsAPlainDictation() async {
        let (c, output, _) = makeCoordinator(engineText: Self.sentence, settings: Self.settings())
        await c.startIdle()
        await c.dictate()
        #expect(output.inserted == [Self.sentence + " "])
    }

    @Test func polishSettingWarmsTheRefiner() async {
        let refiner = FakeRefiner()
        let (c, _, _) = makeCoordinator(engineText: Self.sentence, settings: Self.settings(), refiner: refiner)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(await waitUntil { refiner.prepareCount == 1 })
        #expect(c.state.isRecording)
        #expect(refiner.calls.isEmpty)
    }

    @Test func polishingStateIsPublishedWhileTheModelRuns() async {
        let refiner = FakeRefiner(delay: .milliseconds(200))
        let (c, output, _) = makeCoordinator(engineText: Self.sentence, settings: Self.settings(), refiner: refiner)
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(c.willPolish)
        c.hotkeyReleased()
        #expect(await waitUntil { c.state == .polishing })
        #expect(c.willPolish)
        #expect(output.inserted.isEmpty)
        await c.inFlight?.value
        #expect(c.state == .idle)
        #expect(!c.willPolish)
        #expect(output.inserted == ["polished "])
    }

    @Test func aSecondChordIsStillRegisteredWhenPolishIsAToggle() async {
        let fake = FakeHotkey()
        var settings = Self.settings()
        settings.toggleHotkey = Hotkey(0x3B, 0x3A, 0x31)
        let (c, _, _) = makeCoordinator(settings: settings, hotkeyMonitor: fake)
        await c.startIdle()
        #expect(fake.lastChords == [.dictate: .optionSpace, .toggle: Hotkey(0x3B, 0x3A, 0x31)])
    }

    @Test func theOverrideAppliesOnlyToTheDictateChord() async {
        let fake = FakeHotkey()
        let standIn = Hotkey(0x3B, 0x38, 0x31)
        var settings = Self.settings()
        settings.toggleHotkey = Hotkey(0x3B, 0x3A, 0x31)
        let (c, _, _) = makeCoordinator(settings: settings, hotkeyMonitor: fake)
        c.hotkeyOverride = standIn
        await c.startIdle()
        #expect(fake.lastChords[.dictate] == standIn)
        #expect(fake.lastChords[.toggle] == Hotkey(0x3B, 0x3A, 0x31))
    }

    @Test func aReleaseFromTheOtherChordIsIgnored() async {
        let hotkey = FakeHotkey()
        let refiner = FakeRefiner()
        var settings = Self.settings(polish: false)
        settings.toggleHotkey = Hotkey(0x3B, 0x3A, 0x31)
        let (c, output, _) = makeCoordinator(
            engineText: Self.sentence, settings: settings, hotkeyMonitor: hotkey, refiner: refiner)
        await c.startIdle()
        hotkey.press(.dictate)
        #expect(await waitUntil { c.state.isRecording })
        hotkey.release(.toggle)
        hotkey.cancel(.toggle)
        // Both delivered; neither may end the take.
        #expect(await waitUntil { c.handledHotkeyEvents == 3 })
        #expect(c.state.isRecording)
        hotkey.release(.dictate)
        await c.cycleFinished()
        #expect(output.inserted == [Self.sentence + " "])
        #expect(refiner.calls.isEmpty)
    }

    @Test func cancelledPolishDictationDropsTheRecording() async {
        let hotkey = FakeHotkey()
        let refiner = FakeRefiner()
        let (c, output, capture) = makeCoordinator(
            engineText: Self.sentence, settings: Self.settings(), hotkeyMonitor: hotkey, refiner: refiner)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.cancel()
        #expect(await waitUntil { c.state == .idle })
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        #expect(refiner.calls.isEmpty)
        #expect(!c.willPolish)
    }

    @Test func submitWorksOnThePolishedPath() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(
            engineText: Self.sentence, settings: Self.settings(), hotkeyMonitor: hotkey, refiner: FakeRefiner())
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release(submit: true)
        await c.cycleFinished()
        #expect(output.inserted == ["polished "])
        #expect(output.submitted == [true])
    }

    @Test func cancelRecordingClearsWillPolish() async {
        let (c, _, _) = makeCoordinator(settings: Self.settings(), refiner: FakeRefiner())
        await c.startIdle()
        await c.hotkeyPressed()
        #expect(c.willPolish)
        await c.cancelRecording()
        #expect(!c.willPolish)
        #expect(c.state == .idle)
    }
}

// MARK: - Toggle key

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ToggleHotkeyTests {
    /// Control + D: a toggle chord that is not the push-to-talk chord.
    private static let controlD = Hotkey(0x3B, 0x02)

    private func hybridSettings() -> DictationSettings {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.toggleHotkey = settings.hotkey
        return settings
    }

    private func separateSettings() -> DictationSettings {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.toggleHotkey = Self.controlD
        return settings
    }

    @Test func aHybridTapLatchesAndTheNextTapInserts() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: hybridSettings(), hotkeyMonitor: hotkey)
        c.holdThreshold = .seconds(2)
        await c.startIdle()
        #expect(hotkey.lastChords == [.dictate: .optionSpace])
        await c.press(hotkey)
        hotkey.release()
        #expect(await waitUntil { c.isLatched })
        #expect(c.state.isRecording)
        // A step past the release, well outside the bounce window.
        hotkey.press()
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
        #expect(!c.isLatched)
        // The closing press's release arrives in idle and does nothing.
        hotkey.release()
        #expect(await waitUntil { c.handledHotkeyEvents == 4 })
        #expect(c.state == .idle)
    }

    @Test func aHybridHoldStopsAtRelease() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: hybridSettings(), hotkeyMonitor: hotkey)
        c.holdThreshold = .milliseconds(20)
        await c.startIdle()
        await c.press(hotkey)
        // A step (100 ms) is longer than the threshold: a hold.
        hotkey.release()
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
        #expect(!c.isLatched)
    }

    @Test func theHoldIsTimedByTheEventsOwnInstants() async {
        // The release is delivered late, but it happened 10 ms after the
        // press: a tap, however long the loop took to get to it. The one
        // test that has to sleep: it is about wall time passing.
        let hotkey = FakeHotkey()
        let (c, _, _) = makeCoordinator(settings: hybridSettings(), hotkeyMonitor: hotkey)
        c.holdThreshold = .milliseconds(50)
        await c.startIdle()
        let pressed = ContinuousClock.now
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: pressed))
        #expect(await waitUntil { c.state.isRecording })
        try? await Task.sleep(for: .milliseconds(100))
        hotkey.send(HotkeyMonitorEvent(
            role: .dictate, event: .released(submit: false), instant: pressed + .milliseconds(10)))
        #expect(await waitUntil { c.isLatched })
        await c.cancelRecording()
    }

    @Test func aPlainToggleChordLatchesWhateverTheHoldLength() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: separateSettings(), hotkeyMonitor: hotkey)
        c.holdThreshold = .milliseconds(20)
        await c.startIdle()
        hotkey.press(.toggle)
        #expect(await waitUntil { c.state.isRecording })
        // Held for a step, past the threshold, and still it latches.
        hotkey.release(.toggle)
        #expect(await waitUntil { c.isLatched })
        #expect(c.state.isRecording)
        hotkey.press(.toggle)
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
    }

    @Test func pushToTalkStaysPlainWhenTheChordsDiffer() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: separateSettings(), hotkeyMonitor: hotkey)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release()
        #expect(await waitUntil { c.inFlight != nil })
        #expect(!c.isLatched)
        await c.inFlight?.value
        #expect(output.inserted.count == 1)
    }

    @Test func eitherChordEndsALatchedRecording() async {
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: separateSettings(), hotkeyMonitor: hotkey)
        await c.startIdle()
        hotkey.press(.toggle)
        #expect(await waitUntil { c.state.isRecording })
        hotkey.release(.toggle)
        #expect(await waitUntil { c.isLatched })
        hotkey.press()
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
    }

    @Test func aDifferentToggleChordIsASecondChord() async {
        let hotkey = FakeHotkey()
        let (c, _, _) = makeCoordinator(settings: separateSettings(), hotkeyMonitor: hotkey)
        c.start()
        #expect(hotkey.lastChords == [.dictate: .optionSpace, .toggle: Self.controlD])
    }

    @Test func anEmptyToggleChordIsNoChord() async {
        let hotkey = FakeHotkey()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: hotkey)
        c.start()
        #expect(hotkey.lastChords == [.dictate: .optionSpace])
    }

    @Test func aHybridChordFollowsTheStandIn() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.hotkey = .rightCommand
        settings.toggleHotkey = .rightCommand
        let hotkey = FakeHotkey()
        let (c, _, _) = makeCoordinator(settings: settings, hotkeyMonitor: hotkey)
        c.hotkeyOverride = .optionSpace
        c.holdThreshold = .seconds(2)
        await c.startIdle()
        // Not a second chord Carbon could not register: the stand-in is hybrid.
        #expect(hotkey.lastChords == [.dictate: .optionSpace])
        await c.press(hotkey)
        hotkey.release()
        #expect(await waitUntil { c.isLatched })
        await c.cancelRecording()
    }

    @Test func theCapFiresInToggleMode() async {
        let hotkey = FakeHotkey()
        let clock = ManualClock()
        let (c, output, _) = makeCoordinator(settings: hybridSettings(), hotkeyMonitor: hotkey, clock: clock)
        c.holdThreshold = .seconds(2)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release()
        #expect(await waitUntil { c.isLatched })
        #expect(await waitUntil { clock.sleeperCount >= 2 })
        clock.advance(by: c.maximumDuration)
        await c.cycleFinished()
        #expect(output.inserted.count == 1)
        #expect(output.submitted == [false])
        #expect(!c.isLatched)
        // The latch went with the recording: the next press starts afresh
        // rather than ending a recording that is no longer there.
        await c.press(hotkey)
        await c.cancelRecording()
    }

    @Test func anInterruptedHybridPressStillDiscardsSilently() async {
        let hotkey = FakeHotkey()
        let events = EventLog()
        let (c, output, capture) = makeCoordinator(
            settings: hybridSettings(), hotkeyMonitor: hotkey, events: events)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.cancel()
        #expect(await waitUntil { c.state == .idle })
        #expect(!c.isLatched)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        #expect(events.names == ["recordingStarted"])
    }

    @Test func aRefusedStartDoesNotLatch() async {
        let hotkey = FakeHotkey()
        var settings = DictationSettings(engineID: EngineID("flaky"))
        settings.toggleHotkey = settings.hotkey
        let (c, _, _) = makeCoordinator(
            engines: [.serving(FlakyEngine(failures: 1))], settings: settings, hotkeyMonitor: hotkey)
        c.start()
        #expect(await waitUntil { c.state == .unavailable(.engineFailed(.loadFailed(detail: "boom"))) })
        // A tap while the engine is down: refused, and not remembered as a latch.
        hotkey.press()
        hotkey.release()
        #expect(await waitUntil { c.handledHotkeyEvents == 2 })
        #expect(!c.isLatched)
        c.reloadEngine()
        #expect(await waitUntil { c.state == .idle })
        await c.press(hotkey)
        await c.cancelRecording()
    }

    // MARK: Bounce

    @Test func aBounceIsAnnouncedOnce() async {
        let hotkey = FakeHotkey()
        let events = EventLog()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: hotkey, events: events)
        await c.startIdle()
        await c.press(hotkey)
        let released = hotkey.time + .seconds(1)
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .released(submit: false), instant: released))
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: released + .milliseconds(10)))
        hotkey.send(HotkeyMonitorEvent(
            role: .dictate, event: .released(submit: false), instant: released + .milliseconds(20)))
        hotkey.send(HotkeyMonitorEvent(role: .dictate, event: .pressed, instant: released + .milliseconds(30)))
        #expect(await waitUntil { events.names.contains("keyboardBounceObserved") })
        await c.inFlight?.value
        #expect(events.names.filter { $0 == "keyboardBounceObserved" }.count == 1)
    }
}

// MARK: - Escape

@MainActor
@Suite(.timeLimit(.minutes(1))) struct EscapeTests {
    @Test func escapeDiscardsWithoutPastingAndAnnouncesIt() async {
        let hotkey = FakeHotkey()
        let events = EventLog()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: hotkey, events: events)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.escape()
        // Handled means the cancel has run to its end, microphone included.
        #expect(await waitUntil { c.handledHotkeyEvents == 2 })
        #expect(c.state == .idle)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
        // No `recordingStopped`, so no timing line; `recordingDiscarded` is
        // what plays the stop sound.
        #expect(events.names == ["recordingStarted", "recordingDiscarded"])
        #expect(hotkey.cancelKeyEnabled == [true, false])
    }

    @Test func theReleaseAfterEscapeDoesNothing() async {
        let hotkey = FakeHotkey()
        let (c, output, capture) = makeCoordinator(hotkeyMonitor: hotkey)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.escape()
        hotkey.release()
        #expect(await waitUntil { c.handledHotkeyEvents == 3 })
        #expect(c.state == .idle)
        #expect(c.inFlight == nil)
        #expect(await capture.stopCount == 1)
        #expect(output.inserted.isEmpty)
    }

    @Test func escapeWhileIdleDoesNothing() async {
        let hotkey = FakeHotkey()
        let events = EventLog()
        let (c, _, capture) = makeCoordinator(hotkeyMonitor: hotkey, events: events)
        await c.startIdle()
        hotkey.escape()
        #expect(await waitUntil { c.handledHotkeyEvents == 1 })
        #expect(c.state == .idle)
        #expect(events.names.isEmpty)
        #expect(await capture.stopCount == 0)
        #expect(hotkey.cancelKeyEnabled.isEmpty)
    }

    @Test func escapeWhileLatchedDiscards() async {
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.toggleHotkey = settings.hotkey
        let hotkey = FakeHotkey()
        let (c, output, _) = makeCoordinator(settings: settings, hotkeyMonitor: hotkey)
        c.holdThreshold = .seconds(2)
        await c.startIdle()
        await c.press(hotkey)
        hotkey.release()
        #expect(await waitUntil { c.isLatched })
        hotkey.escape()
        #expect(await waitUntil { c.state == .idle })
        #expect(!c.isLatched)
        #expect(output.inserted.isEmpty)
        // Not latched any more: the next press starts a recording.
        await c.press(hotkey)
        await c.cancelRecording()
    }

    @Test func theCancelKeyIsOnlyOnWhileRecording() async {
        let hotkey = FakeHotkey()
        let clock = ManualClock()
        let (c, _, _) = makeCoordinator(hotkeyMonitor: hotkey, clock: clock)
        await c.startIdle()
        // A dictation.
        await c.press(hotkey)
        hotkey.release()
        await c.cycleFinished()
        #expect(hotkey.cancelKeyEnabled == [true, false])
        // An interrupted press, a step past that release.
        await c.press(hotkey)
        hotkey.cancel()
        #expect(await waitUntil { c.state == .idle })
        #expect(hotkey.cancelKeyEnabled == [true, false, true, false])
        // The cap: it and the warm loop wait on the clock.
        await c.hotkeyPressed()
        #expect(await waitUntil { clock.sleeperCount >= 2 })
        clock.advance(by: c.maximumDuration)
        #expect(await waitUntil { !c.state.isRecording })
        await c.inFlight?.value
        #expect(hotkey.cancelKeyEnabled == [true, false, true, false, true, false])
    }
}
