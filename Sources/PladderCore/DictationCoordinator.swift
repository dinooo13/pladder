import Foundation
import Observation

// See docs/ARCHITECTURE.md, "Dictation flow".
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var state: DictationState = .unavailable(.starting)
    public private(set) var engineStatus: EngineStatus = .unloaded
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastError: DictationFailure?
    public private(set) var inputLevel: Float = 0
    public private(set) var partialTranscript: String?
    public private(set) var willPolish = false
    public private(set) var isLatched = false
    public private(set) var inFlight: Task<Void, Never>?

    public var settings: DictationSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    public var isHotkeySuspended = false {
        didSet {
            guard isHotkeySuspended != oldValue else { return }
            if isHotkeySuspended {
                stopHotkey()
                dropRecording()
            } else {
                hotkeyConfigurationChanged()
            }
        }
    }

    // Stands in for a stored chord Carbon cannot register while Accessibility is missing.
    public var hotkeyOverride: Hotkey? {
        didSet {
            guard hotkeyOverride != oldValue else { return }
            hotkeyConfigurationChanged()
        }
    }

    public var minimumDuration: TimeInterval = 0.3
    public var minimumPolishWords = 4
    // A key-up can be lost for real, e.g. while Secure Event Input hides keys from the tap.
    public var maximumDuration: Duration = .seconds(600)
    // Handy and VoiceInk use 300 to 500 ms.
    public var holdThreshold: Duration = .milliseconds(400)
    public var bounceWindow: Duration = .milliseconds(50)
    public var deferReleases = false
    public var errorDisplayDuration: Duration = .seconds(2)

    // On an M1 a pass after ten seconds idle costs about 110 ms more than one made
    // back to back: more than the capture stop, the processors and the paste together.
    public var warmupInterval: Duration = .seconds(2)
    public var livePassInterval: Duration = .milliseconds(500)
    public var feedInterval: Duration = .seconds(1)

    private let loader: EngineLoader
    private let capture: any AudioCapture
    private let output: any TextOutput
    private let outputMuter: (any OutputMuter)?
    private let refiner: (any TranscriptRefiner)?
    private var hotkeyMonitor: any HotkeyMonitor
    private let makePipeline: @Sendable (DictationSettings) -> ProcessorPipeline
    // Built when settings change, never on the release path: `DictionaryReplacer`
    // compiles a regex per entry.
    private var pipeline: ProcessorPipeline
    private let clock: any Clock<Duration>
    private let onEvent: @Sendable (Event) -> Void

    private var isStarted = false
    private var hotkeyTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var transientResetTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var gesture = HotkeyGestureTracker(modes: [:])
    private var settleTask: Task<Void, Never>?
    private var pendingUnloads: [any TranscriptionEngine] = []
    private var cycleEngine: (any TranscriptionEngine)?

    // Cancelling cannot abort a CoreML call already started, so a release landing in
    // a warm pass waits for it; the log shows that as `engine` above `engine-time`.
    private var warmupTask: Task<Void, Never>?
    private var feedTask: Task<Int, Never>?
    private var recording = 0
    private var cancelCleanup: Task<Void, Never>?
    private var muteRestoreTask: Task<Void, Never>?

    // Every utterance is padded to the model's full window, so half a second of
    // silence costs the same encoder pass as a real call.
    private static let warmupSamples = [Float](repeating: 0, count: 8_000)

    @ObservationIgnored private(set) var handledHotkeyEvents = 0

    public struct CycleTiming: Sendable, Equatable {
        public var captureStop: Duration
        public var engine: Duration
        public var processing: Duration
        public var insert: Duration
        // Nil without polish; zero when the transcript was too short for it.
        public var polish: Duration?
    }

    public struct Insertion: Sendable, Equatable {
        public var transcript: Transcript
        public var timing: CycleTiming
        public var result: InsertResult
        public var submitted: Bool
    }

    public enum Event: Sendable {
        case recordingStarted
        case recordingStopped
        case inserted(Insertion)
        case failed(DictationFailure)
        case recordingDiscarded
        case keyboardBounceObserved
    }

    public init(
        settings: DictationSettings,
        registry: EngineRegistry,
        capture: any AudioCapture,
        output: any TextOutput,
        outputMuter: (any OutputMuter)? = nil,
        refiner: (any TranscriptRefiner)? = nil,
        hotkeyMonitor: any HotkeyMonitor,
        makePipeline: @escaping @Sendable (DictationSettings) -> ProcessorPipeline,
        clock: any Clock<Duration> = ContinuousClock(),
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.settings = settings
        self.capture = capture
        self.output = output
        self.outputMuter = outputMuter
        self.refiner = refiner
        self.hotkeyMonitor = hotkeyMonitor
        self.makePipeline = makePipeline
        self.pipeline = makePipeline(settings)
        self.clock = clock
        self.onEvent = onEvent
        loader = EngineLoader(registry: registry, engineID: settings.engineID)
        loader.onStatusChange = { [weak self] in self?.setEngineStatus($0) }
    }

    // MARK: Lifecycle

    public func start() {
        isStarted = true
        if !isHotkeySuspended { startHotkey() }
        Task { try? await capture.warmUp() }
        loader.load()
    }

    public func stop() {
        isStarted = false
        stopHotkey()
        loader.stop()
        transientResetTask?.cancel()
        dropRecording()
    }

    public func shutdown() async {
        isStarted = false
        stopHotkey()
        loader.stop()
        transientResetTask?.cancel()
        if state.isRecording { await cancelRecording() }
        await inFlight?.value
        await muteRestoreTask?.value
        await output.flush()
    }

    public func reloadEngine() {
        loader.load()
    }

    public func replaceHotkeyMonitor(_ monitor: any HotkeyMonitor) {
        stopHotkey()
        hotkeyMonitor = monitor
        hotkeyConfigurationChanged()
    }

    private func setEngineStatus(_ status: EngineStatus) {
        engineStatus = status
        if status.isReady {
            if case .unavailable = state { becomeIdle() }
        } else if !state.isBusy {
            becomeIdle()
        }
    }

    private func settingsChanged(from old: DictationSettings) {
        guard settings != old else { return }
        pipeline = makePipeline(settings)
        if old.hotkey != settings.hotkey || old.submitKey != settings.submitKey
            || old.toggleHotkey != settings.toggleHotkey {
            hotkeyConfigurationChanged()
        }
        if old.engineID != settings.engineID, let previous = loader.select(settings.engineID) {
            // The running cycle transcribes with the engine that was ready at press, so the
            // replaced one is unloaded only once the cycle ends.
            if state.isBusy {
                pendingUnloads.append(previous)
            } else {
                Task { await previous.unload() }
            }
        }
    }

    private func drainPendingUnloads() {
        guard !pendingUnloads.isEmpty else { return }
        let engines = pendingUnloads
        pendingUnloads = []
        Task {
            for engine in engines { await engine.unload() }
        }
    }

    // MARK: Hotkey

    // A release from the old configuration never arrives on the new stream, so a
    // recording in progress is dropped.
    private func hotkeyConfigurationChanged() {
        dropRecording()
        guard isStarted, !isHotkeySuspended else { return }
        startHotkey()
    }

    private func stopHotkey() {
        hotkeyTask?.cancel()
        hotkeyTask = nil
        hotkeyMonitor.stop()
    }

    private func dropRecording() {
        guard state.isRecording else { return }
        Task { await cancelRecording() }
    }

    private func startHotkey() {
        stopHotkey()
        startGesture()
        var chords: [HotkeyRole: Hotkey] = [.dictate: hotkeyOverride ?? settings.hotkey]
        if let toggle = separateToggleChord { chords[.toggle] = toggle }
        let stream = hotkeyMonitor.start(chords: chords, submitKey: settings.submitKey)
        hotkeyTask = Task { [weak self] in
            for await tagged in stream {
                guard let self else { return }
                await self.handle(tagged)
                self.handledHotkeyEvents += 1
            }
        }
    }

    private func handle(_ tagged: HotkeyMonitorEvent) async {
        // When the key moved, not when this loop got to it: a press waits here for the mic.
        let at = tagged.instant ?? .now
        switch tagged.kind {
        case .chord(let role, .pressed):
            let wasDeferring = gesture.deferReleases
            let outcome = gesture.pressed(role, at: at)
            if gesture.deferReleases, !wasDeferring { onEvent(.keyboardBounceObserved) }
            await act(outcome)
        case .chord(let role, .released(let submit)):
            await act(gesture.released(role, submit: submit, at: at))
        case .chord(let role, .cancelled):
            await act(gesture.interrupted(role))
        case .escape:
            await escapePressed()
        }
    }

    private var toggleIsHybrid: Bool {
        let toggle = settings.toggleHotkey.canonical
        guard !toggle.isEmpty else { return false }
        return toggle == settings.hotkey.canonical || toggle == hotkeyOverride?.canonical
    }

    private var separateToggleChord: Hotkey? {
        settings.toggleHotkey.isEmpty || toggleIsHybrid ? nil : settings.toggleHotkey
    }

    // A bounce seen before is remembered: the keyboard did not change with the monitor.
    private func startGesture() {
        settleTask?.cancel()
        settleTask = nil
        isLatched = false
        gesture = HotkeyGestureTracker(
            modes: [.dictate: toggleIsHybrid ? .hybrid : .hold, .toggle: .toggle],
            holdThreshold: holdThreshold,
            bounceWindow: bounceWindow,
            deferReleases: deferReleases || gesture.deferReleases
        )
    }

    private func act(_ outcome: HotkeyGestureTracker.Outcome) async {
        if let settle = outcome.settle { armSettle(settle) }
        switch outcome.action {
        case .start:
            await hotkeyPressed()
            // A refused press (engine loading, cycle in flight, mic failed) must not leave
            // the tracker holding or latching a recording that never began.
            if !state.isRecording { gesture.reset() }
        case .stop(let submit):
            hotkeyReleased(submit: submit)
        case .discard:
            await cancelRecording()
        case nil:
            break
        }
        isLatched = gesture.isLatched && state.isRecording
    }

    private func armSettle(_ settle: HotkeyGestureTracker.Settle) {
        settleTask?.cancel()
        settleTask = Task { [weak self, clock] in
            try? await clock.sleep(for: settle.after)
            guard let self, !Task.isCancelled else { return }
            await self.act(self.gesture.timerFired(token: settle.token))
        }
    }

    // MARK: Recording

    public func hotkeyPressed() async {
        switch state {
        case .idle: break
        case .copied: transientResetTask?.cancel()
        default: return
        }
        guard engineStatus.isReady else { return }
        cycleEngine = loader.engine
        willPolish = settings.polishDictations
        partialTranscript = nil
        // Read once, at press: a style switch mid-recording must not leave the loop half live.
        let live = settings.liveTranscript
        // Flip state before the await so the overlay reacts on key-down and a second
        // concurrent press cannot start capture twice.
        state = .recording
        inputLevel = 0
        recording += 1
        let mine = recording
        hotkeyMonitor.setCancelKeyEnabled(true)
        // Waits for the last cancel's `abandonUtterance`, so it cannot drop this new
        // utterance in place of the old one.
        await cancelCleanup?.value
        let levels: AsyncStream<Float>
        do {
            levels = try await capture.start()
        } catch {
            guard isCurrent(mine) else { return }
            willPolish = false
            endRecording()
            cycleEngine = nil
            fail(.microphone(detail: error.localizedDescription))
            return
        }
        guard isCurrent(mine) else {
            // The cancel already ended the recording, but the mic came up after its stop.
            // A newer recording, if one has started since, owns it now.
            if !state.isRecording { _ = await capture.stop() }
            return
        }
        onEvent(.recordingStarted)
        armOutputMute()
        startKeyDownWork()
        await startEngineWork(live: live, recording: mine)
        guard isCurrent(mine) else { return }
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self, self.state.isRecording else { return }
                self.inputLevel = level
            }
        }
        maxDurationTask = Task { [weak self, clock, maximumDuration] in
            try? await clock.sleep(for: maximumDuration)
            guard let self, !Task.isCancelled, self.state.isRecording else { return }
            // A lost key-up, not a release: never send a message unattended.
            self.hotkeyReleased(submit: false)
        }
    }

    // The clipboard snapshot and the polish model's load (about 700 ms cold) run
    // while the user is still speaking.
    private func startKeyDownWork() {
        Task { [weak self] in await self?.output.prepare() }
        if willPolish, let refiner {
            Task.detached(priority: .utility) { await refiner.prepare() }
        }
    }

    private func isCurrent(_ id: Int) -> Bool {
        state.isRecording && recording == id
    }

    // A streaming engine that cannot begin an utterance is used like a batch engine:
    // transcribed whole at release, slower but not lost.
    private func startEngineWork(live: Bool, recording id: Int) async {
        if let streaming = cycleEngine as? (any StreamingTranscriptionEngine),
           (try? await streaming.beginUtterance()) != nil {
            guard isCurrent(id) else {
                // A newer recording's `beginUtterance` replaces this one, so only drop it when
                // there is none.
                if !state.isRecording { await streaming.abandonUtterance() }
                return
            }
            startStreamingFeed(streaming, live: live)
            // The live loop's pass is the warm pass; a second loop would only compete with it.
            if !live { startWarmupLoop { await streaming.warmPass() } }
        } else if let engine = cycleEngine {
            startWarmupLoop { [warmupSamples = Self.warmupSamples] in
                _ = try? await engine.transcribe(warmupSamples)
            }
        }
    }

    // One loop for feed and live passes, so they never drain against each other. At
    // release the loop is cancelled and awaited: a chunk drained just before is still
    // fed, so every sample reaches the engine once and in order.
    private func startStreamingFeed(_ engine: any StreamingTranscriptionEngine, live: Bool) {
        feedTask = Task { [weak self, clock, feedInterval, livePassInterval] in
            var fed = 0
            while !Task.isCancelled {
                if !live { try? await clock.sleep(for: feedInterval) }
                guard let self, !Task.isCancelled, self.state.isRecording else { return fed }
                let chunk = await self.capture.drain()
                if !chunk.isEmpty {
                    fed += chunk.count
                    await engine.feed(chunk)
                }
                guard live, !Task.isCancelled else { continue }
                let text = await engine.livePass()
                // A pass finishing after the release would put stale text back on screen.
                guard !Task.isCancelled, self.state.isRecording else { return fed }
                self.partialTranscript = text
                try? await clock.sleep(for: livePassInterval)
            }
            return fed
        }
    }

    private func startWarmupLoop(_ warm: @escaping @Sendable () async -> Void) {
        warmupTask?.cancel()
        warmupTask = Task.detached(priority: .utility) { [clock, interval = warmupInterval] in
            while !Task.isCancelled {
                await warm()
                if Task.isCancelled { return }
                try? await clock.sleep(for: interval)
            }
        }
    }

    private func armOutputMute() {
        guard settings.muteOutputWhileDictating, let outputMuter else { return }
        let session = recording
        Task { await outputMuter.recordingStarted(session: session) }
    }

    // Not gated on the setting: turning it off mid-recording must still restore the
    // device. Detached so the paste never waits on CoreAudio.
    private func restoreOutputDevice() {
        guard let outputMuter else { return }
        let session = recording
        let previous = muteRestoreTask
        muteRestoreTask = Task.detached(priority: .utility) {
            await previous?.value
            await outputMuter.recordingEnded(session: session)
        }
    }

    // Synchronous, and every call only flips a flag, cancels a task or spawns one,
    // so on the release path this costs nothing before `recordingStopped`.
    @discardableResult
    private func endRecording() -> Task<Int, Never>? {
        settleTask?.cancel()
        settleTask = nil
        gesture.reset()
        isLatched = false
        hotkeyMonitor.setCancelKeyEnabled(false)
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
        maxDurationTask?.cancel()
        maxDurationTask = nil
        let feed = feedTask
        feed?.cancel()
        feedTask = nil
        // Before the state flip, so no further pass is queued ahead of the real call.
        warmupTask?.cancel()
        warmupTask = nil
        partialTranscript = nil
        restoreOutputDevice()
        return feed
    }

    public func hotkeyReleased(submit: Bool = false) {
        guard state.isRecording else { return }
        let feed = endRecording()
        state = .transcribing
        // Snapshots anything copied while speaking now, beside the engine pass, not in
        // the paste.
        Task { [weak self] in await self?.output.prepare() }
        onEvent(.recordingStopped)
        let engine = cycleEngine ?? loader.engine
        cycleEngine = nil
        inFlight = Task { [weak self] in
            guard let self else { return }
            // The feed loop finishes handing over a chunk drained before the release. What
            // it waits for is engine work `endUtterance` would wait for anyway: engine time.
            let handover = ContinuousClock.now
            let fed = await feed?.value
            let stopped = ContinuousClock.now
            let feedWait = stopped - handover
            let audio = await self.capture.stop()
            let captureStop = ContinuousClock.now - stopped
            await self.finish(
                audio, fedSamples: fed, with: engine, submit: submit, captureStop: captureStop, feedWait: feedWait)
        }
    }

    private func finish(
        _ audio: CapturedAudio,
        fedSamples: Int?,
        with engine: any TranscriptionEngine,
        submit: Bool,
        captureStop: Duration,
        feedWait: Duration
    ) async {
        defer {
            drainPendingUnloads()
            willPolish = false
        }
        let streaming = fedSamples == nil ? nil : engine as? (any StreamingTranscriptionEngine)
        // A streaming engine was fed `fedSamples` while recording; only the tail came
        // from `stop()`.
        let totalDuration = Double((fedSamples ?? 0) + audio.samples.count) / CapturedAudio.sampleRate
        guard totalDuration >= minimumDuration else {
            await streaming?.abandonUtterance()
            becomeIdle()
            return
        }
        do {
            var timing = CycleTiming(captureStop: captureStop, engine: .zero, processing: .zero, insert: .zero)
            var started = ContinuousClock.now
            var transcript = if let streaming {
                try await streaming.endUtterance(audio.samples)
            } else {
                try await engine.transcribe(audio.samples)
            }
            timing.engine = feedWait + (ContinuousClock.now - started)
            if transcript.audioDuration == 0 {
                transcript.audioDuration = totalDuration
            }
            lastTranscript = transcript
            started = ContinuousClock.now
            let processed = pipeline.run(transcript.text, disabled: settings.disabledProcessors)
            timing.processing = ContinuousClock.now - started
            guard !processed.isEmpty else {
                becomeIdle()
                return
            }
            var final = processed
            if willPolish, let refiner, Self.wordCount(processed) >= minimumPolishWords {
                state = .polishing
                started = ContinuousClock.now
                if let polished = await refiner.refine(processed) { final = polished }
                timing.polish = ContinuousClock.now - started
            } else if willPolish {
                timing.polish = .zero
            }
            state = .inserting
            let needsSpace = settings.appendTrailingSpace && final.last?.isWhitespace != true
            let toInsert = needsSpace ? final + " " : final
            started = ContinuousClock.now
            let result = try await output.insert(toInsert, submit: submit)
            timing.insert = ContinuousClock.now - started
            transcript.text = final
            lastTranscript = transcript
            onEvent(.inserted(Insertion(
                transcript: transcript, timing: timing, result: result,
                submitted: submit && result == .pasted)))
            if result == .copied { showCopied() } else { becomeIdle() }
        } catch {
            fail(DictationFailure(error))
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func becomeIdle() {
        switch engineStatus {
        case .ready: state = .idle
        case .failed(let failure): state = .unavailable(.engineFailed(failure))
        case .unloaded, .downloading, .loading: state = .unavailable(.loadingModel)
        }
    }

    public func cancelRecording() async {
        guard state.isRecording else { return }
        let feed = endRecording()
        willPolish = false
        becomeIdle()
        let engine = feed == nil ? nil : cycleEngine as? (any StreamingTranscriptionEngine)
        cycleEngine = nil
        // The mic goes off first; the engine drops the utterance only once the feed has
        // exited, so no chunk lands after it.
        let cleanup = Task { [capture] in
            _ = await capture.stop()
            _ = await feed?.value
            await engine?.abandonUtterance()
        }
        cancelCleanup = cleanup
        await cleanup.value
        drainPendingUnloads()
    }

    // Before the mic has finished stopping, so the stop sound is not late.
    public func escapePressed() async {
        guard state.isRecording else { return }
        onEvent(.recordingDiscarded)
        await cancelRecording()
    }

    private func showCopied() {
        state = .copied
        becomeIdle(after: settings.copiedHoldDuration)
    }

    private func fail(_ failure: DictationFailure) {
        lastError = failure
        state = .error(failure)
        onEvent(.failed(failure))
        becomeIdle(after: errorDisplayDuration)
    }

    private func becomeIdle(after hold: Duration) {
        let shown = state
        transientResetTask?.cancel()
        transientResetTask = Task { [weak self, clock] in
            try? await clock.sleep(for: hold)
            guard let self, !Task.isCancelled, self.state == shown else { return }
            self.becomeIdle()
        }
    }
}
