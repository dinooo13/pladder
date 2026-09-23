import Foundation
import Observation

/// The push-to-talk state machine. Owns no I/O itself; everything is injected.
///
/// Flow: hotkey pressed -> capture starts -> hotkey released -> capture stops ->
/// engine transcribes -> pipeline processes -> output inserts -> idle.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var state: DictationState = .unavailable(.starting)
    public private(set) var engineStatus: EngineStatus = .unloaded
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastError: DictationFailure?

    /// What the engine makes of the recording so far, for the Live Transcript
    /// overlay. Display only: it is never processed and never inserted, and it
    /// is cleared the moment the key is released. Nil in every other style.
    public private(set) var partialTranscript: String?

    /// The transcribe → process → insert work for the most recent release.
    /// Exposed so callers (and tests) can await completion of a cycle.
    public private(set) var inFlight: Task<Void, Never>?

    public var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }

    /// True while the settings window is recording a new chord. The monitor
    /// is taken down so the keys the user presses to define the new hotkey
    /// cannot fire the old one, and a recording in progress is dropped.
    public var isHotkeySuspended = false {
        didSet {
            guard isHotkeySuspended != oldValue else { return }
            if isHotkeySuspended {
                hotkeyTask?.cancel()
                hotkeyMonitor.stop()
                if state.isRecording {
                    Task { await cancelRecording() }
                }
            } else {
                startHotkey()
            }
        }
    }

    /// The chord the monitor listens for in place of `settings.hotkey`.
    ///
    /// Set by the app while Accessibility is missing and the stored chord
    /// cannot be registered without it — a modifier-only chord such as Right
    /// Command, which the default Option+Space then stands in for. The stored
    /// chord is left untouched and comes back the moment this is cleared,
    /// which is what happens when Accessibility is granted. Nil means "listen
    /// for the stored chord".
    public var hotkeyOverride: Hotkey? {
        didSet {
            guard hotkeyOverride != oldValue else { return }
            // The old chord's release can no longer arrive, exactly as for a
            // stored-chord change or a monitor swap.
            if state.isRecording {
                Task { await cancelRecording() }
            }
            // Before `start()` there is nothing to restart, and `start()`
            // reads the override itself, so setting it at launch costs one
            // registration rather than two.
            guard hotkeyTask != nil, !isHotkeySuspended else { return }
            startHotkey()
        }
    }

    /// Minimum recording length worth transcribing. Taps shorter than this are
    /// treated as accidental.
    public var minimumDuration: TimeInterval = 0.3
    /// Recordings are cut off after this long. A release event can be lost for
    /// real, for example while a secure password field has focus and global
    /// monitors receive nothing, and this keeps the microphone from staying on.
    public var maximumDuration: Duration = .seconds(600)
    /// How long an error stays on screen before returning to idle.
    public var errorDisplayDuration: Duration = .seconds(2)
    /// How long the "press ⌘V" hint stays on screen before returning to idle.
    /// Nil follows the overlay animation speed; tests set it directly.
    public var copiedDisplayDuration: Duration?

    private let loader: EngineLoader
    private let capture: any AudioCapture
    private let output: any TextOutput
    /// Silences the speakers while the mic is open, when the setting is on.
    /// Nil in tests and wherever the app does not want the behaviour at all.
    private let outputMuter: (any OutputMuter)?
    private var hotkeyMonitor: any HotkeyMonitor
    private let makePipeline: @Sendable (Settings) -> ProcessorPipeline
    /// Rebuilt when settings change so that no processor is constructed on the
    /// release-to-paste path; `DictionaryReplacer` compiles a regex per entry.
    private var pipeline: ProcessorPipeline
    private let onEvent: @Sendable (Event) -> Void

    private var hotkeyTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    /// Returns `.error` or `.copied` to idle after its display duration.
    /// Only one of the two is ever on screen, so they share a task.
    private var transientResetTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?

    /// Wall-clock time of each stage between the hotkey release and the paste.
    public struct CycleTiming: Sendable, Equatable {
        public var captureStop: Duration
        public var engine: Duration
        public var processing: Duration
        public var insert: Duration

        public init(captureStop: Duration, engine: Duration, processing: Duration, insert: Duration) {
            self.captureStop = captureStop
            self.engine = engine
            self.processing = processing
            self.insert = insert
        }
    }

    public enum Event: Sendable {
        case recordingStarted
        case recordingStopped
        case inserted(Transcript, CycleTiming)
        case failed(DictationFailure)
    }

    public init(
        settings: Settings,
        registry: EngineRegistry,
        capture: any AudioCapture,
        output: any TextOutput,
        outputMuter: (any OutputMuter)? = nil,
        hotkeyMonitor: any HotkeyMonitor,
        makePipeline: @escaping @Sendable (Settings) -> ProcessorPipeline,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.settings = settings
        self.capture = capture
        self.output = output
        self.outputMuter = outputMuter
        self.hotkeyMonitor = hotkeyMonitor
        self.makePipeline = makePipeline
        self.pipeline = makePipeline(settings)
        self.onEvent = onEvent
        loader = EngineLoader(registry: registry, engineID: settings.engineID)
        loader.onStatusChange = { [weak self] in self?.setEngineStatus($0) }
    }

    // MARK: Lifecycle

    /// Loads the engine, warms the mic, and starts listening for the hotkey.
    public func start() {
        if !isHotkeySuspended { startHotkey() }
        Task { try? await capture.warmUp() }
        loader.load()
    }

    public func stop() {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        loader.stop()
        levelTask?.cancel()
        transientResetTask?.cancel()
        maxDurationTask?.cancel()
        if state.isRecording {
            Task { await cancelRecording() }
        }
    }

    /// Re-run engine load, for example after a failed download.
    public func reloadEngine() {
        loader.load()
    }

    /// Swaps the hotkey source, for example when Accessibility is granted or
    /// revoked and the app moves between the event tap and Carbon. The old
    /// monitor's release would never arrive on the new stream, so a recording
    /// in progress is dropped, exactly as for a chord change.
    public func replaceHotkeyMonitor(_ monitor: any HotkeyMonitor) {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        hotkeyMonitor = monitor
        if state.isRecording {
            Task { await cancelRecording() }
        }
        if !isHotkeySuspended { startHotkey() }
    }

    private func setEngineStatus(_ status: EngineStatus) {
        engineStatus = status
        switch status {
        case .ready:
            if case .unavailable = state { state = .idle }
        case .failed(let failure):
            if !state.isBusy { state = .unavailable(.engineFailed(failure)) }
        case .downloading, .loading, .unloaded:
            if !state.isBusy { state = .unavailable(.loadingModel) }
        }
    }

    private func settingsChanged(from old: Settings) {
        // Rebuilt here so that no processor is constructed on the
        // release-to-paste path; `DictionaryReplacer` compiles a regex per
        // entry. `AppModel.settings` ignores assignments that change nothing,
        // so this runs only on real changes.
        pipeline = makePipeline(settings)
        if old.hotkey != settings.hotkey || old.submitKey != settings.submitKey {
            // The old key's release will never arrive on the new stream.
            // The submit key counts too: the restarted monitor would never
            // deliver the pending release for the old configuration.
            if state.isRecording {
                Task { await cancelRecording() }
            }
            if !isHotkeySuspended { startHotkey() }
        }
        if old.engineID != settings.engineID, let previous = loader.select(settings.engineID) {
            // The replaced engine is unloaded only once nothing is using it:
            // the running cycle transcribes with the engine that was ready at
            // press, and unloading it mid-cycle would lose the dictation.
            // The new engine's "Loading model" state arrives through
            // `onStatusChange`.
            if state.isBusy {
                pendingUnloads.append(previous)
            } else {
                Task { await previous.unload() }
            }
        }
    }

    /// Engines replaced by a settings change while a cycle was still running.
    /// Unloaded when the cycle ends.
    private var pendingUnloads: [any TranscriptionEngine] = []

    /// The engine that was ready when the current recording started. Nil
    /// between cycles.
    private var cycleEngine: (any TranscriptionEngine)?

    /// Half a second of silence. Transcribing it at key-down brings the
    /// Neural Engine up from idle while the user is still speaking; every
    /// utterance is padded to the model's full window, so this is the same
    /// encoder pass the real call makes.
    private static let warmupSamples = [Float](repeating: 0, count: 8_000)

    /// How long the Neural Engine is left idle between warm passes. One pass
    /// at key-down is not enough for a long dictation: on an M1 a pass after
    /// ten seconds of idle costs about 110 ms more than one made back to back,
    /// and that is larger than the capture stop, the processors and the paste
    /// together. Settable so tests do not have to wait seconds.
    public var warmupInterval: Duration = .seconds(2)

    /// How often the Live Transcript style asks the engine what it has heard
    /// so far. A live pass costs what a warm pass costs, so this is the warm
    /// interval with a much shorter fuse: four times a second of Neural Engine
    /// time buys text that keeps up with the speaker, at the price of a
    /// release being more likely to land inside a pass. Settable for tests.
    public var livePassInterval: Duration = .milliseconds(500)

    /// Keeps the engine warm for as long as the key is held.
    ///
    /// Cancelled at release, but cancellation cannot abort a CoreML call that
    /// has already started, so a release landing inside a warm pass waits for
    /// it. That is bounded by one pass and shows in the log as `engine`
    /// exceeding `engine-time`. The interval trades that risk against the cold
    /// penalty: longer means more dictations start cold, shorter means more
    /// land on a pass in flight. The live pass in the feed loop has exactly
    /// the same property, at its own cadence.
    private var warmupTask: Task<Void, Never>?

    /// Streaming state for the current recording. Non-nil only when
    /// `cycleEngine` is a `StreamingTranscriptionEngine`.
    private var feedTask: Task<Void, Never>?
    /// Samples handed to the streaming engine so far; the tail from `stop()`
    /// completes the utterance at release.
    private var fedSampleCount = 0

    /// Feeds a second of captured audio at a time to the engine while the
    /// user is still speaking, so the sliding-window engine confirms chunks
    /// before release. Skipped chunks are not a loss: `stop()` returns only
    /// what came after the last drain, and anything a `drain()` raced is
    /// recovered by the tail.
    ///
    /// In `live` mode the same loop also asks the engine for the text so far
    /// and publishes it, on the `livePassInterval` cadence. One loop and not
    /// two: two would drain the same chunks against each other, and a live
    /// pass could overlap the next one.
    private func startStreamingFeed(_ engine: any StreamingTranscriptionEngine, live: Bool) {
        fedSampleCount = 0
        feedTask = Task { [weak self] in
            while !Task.isCancelled {
                if !live { try? await Task.sleep(for: .seconds(1)) }
                guard let self, !Task.isCancelled, self.state.isRecording else { return }
                let chunk = await self.capture.drain()
                if !chunk.isEmpty {
                    await engine.feed(chunk)
                    self.fedSampleCount += chunk.count
                }
                guard live else { continue }
                let text = await engine.livePass()
                // A pass that finishes after the release belongs to a
                // recording that is already on its way to the clipboard;
                // publishing it would put stale text back on screen.
                guard !Task.isCancelled, self.state.isRecording else { return }
                self.partialTranscript = text
                try? await Task.sleep(for: self.livePassInterval)
            }
        }
    }

    /// Warms once immediately, so a short dictation still gets the key-down
    /// pass, then keeps warming until cancelled. Detached and at utility
    /// priority so it never competes with the feed or the UI.
    private func startWarmupLoop(_ warm: @escaping @Sendable () async -> Void) {
        warmupTask?.cancel()
        warmupTask = Task.detached(priority: .utility) { [interval = warmupInterval] in
            while !Task.isCancelled {
                await warm()
                if Task.isCancelled { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopWarmupLoop() {
        warmupTask?.cancel()
        warmupTask = nil
    }

    /// Stops the feed and tells the streaming engine the utterance was
    /// discarded. Safe to call when nothing streaming was started.
    private func abandonStreaming() {
        feedTask?.cancel()
        feedTask = nil
        fedSampleCount = 0
        let engine = cycleEngine
        Task {
            if let streaming = engine as? (any StreamingTranscriptionEngine) {
                await streaming.abandonUtterance()
            }
        }
    }

    /// Wraps the two engine entry points behind one call so `finish` can
    /// transcribe with either kind. For a streaming engine only the tail is
    /// pushed through `endUtterance`; the rest went through `feed` while the
    /// user was speaking. The returned Transcript carries the whole
    /// utterance's audio duration either way.
    private func transcribeCycle(
        tailSamples: [Float],
        with engine: any TranscriptionEngine
    ) async throws -> Transcript {
        guard let streaming = engine as? (any StreamingTranscriptionEngine) else {
            return try await engine.transcribe(tailSamples)
        }
        return try await streaming.endUtterance(tailSamples)
    }

    // MARK: Hotkey

    private func drainPendingUnloads() {
        guard !pendingUnloads.isEmpty else { return }
        let engines = pendingUnloads
        pendingUnloads = []
        Task {
            for engine in engines { await engine.unload() }
        }
    }

    private func startHotkey() {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        let stream = hotkeyMonitor.start(
            hotkey: hotkeyOverride ?? settings.hotkey, submitKey: settings.submitKey)
        hotkeyTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .pressed: await self.hotkeyPressed()
                case .released(let submit): self.hotkeyReleased(submit: submit)
                // Another key went down right after the chord: the user typed
                // Cmd+C, not a dictation. Drop the audio without transcribing,
                // without a stop sound and without a timing line.
                case .cancelled: await self.cancelRecording()
                }
            }
        }
    }

    /// Public so tests and a menu item can drive the state machine directly.
    public func hotkeyPressed() async {
        // `.copied` is the hint from the previous dictation, not a busy state:
        // a press replaces it rather than being dropped.
        switch state {
        case .idle: break
        case .copied: transientResetTask?.cancel()
        default: return
        }
        guard engineStatus.isReady else { return }
        // The engine that was ready at press transcribes this cycle, even if
        // the settings switch engines mid-recording.
        cycleEngine = loader.engine
        partialTranscript = nil
        // Read once, at press: switching the style mid-recording must not
        // leave the loop half live, with nothing warming the engine.
        let live = settings.overlayStyle == .liveTranscript
        // Flip state before the await so the overlay reacts on key-down and a
        // second concurrent press cannot start capture twice.
        state = .recording(level: 0)
        do {
            let levels = try await capture.start()
            guard state.isRecording else {
                // Cancelled or superseded while the mic was starting.
                _ = await capture.stop()
                abandonStreaming()
                return
            }
            onEvent(.recordingStarted)
            // Read at press, so flipping the setting mid-recording cannot
            // arm a mute half way through. The muter waits out its own delay
            // before touching anything, so this is off the key-down path too.
            if settings.muteOutputWhileDictating, let outputMuter {
                Task { await outputMuter.recordingStarted() }
            }
            // Work that keeps the release-to-paste path short: the clipboard
            // snapshot and, for batch engines, a Neural Engine warm-up (the
            // feed below does that for streaming engines). Both run while the
            // user is still speaking.
            Task { [weak self] in await self?.output.prepare() }
            if let streaming = cycleEngine as? (any StreamingTranscriptionEngine) {
                try? await streaming.beginUtterance()
                startStreamingFeed(streaming, live: live)
                // The live loop's pass is the warm pass, so a second loop
                // would only compete with it for the Neural Engine.
                if !live { startWarmupLoop { await streaming.warmPass() } }
            } else if let engine = cycleEngine {
                startWarmupLoop { [warmupSamples = Self.warmupSamples] in
                    _ = try? await engine.transcribe(warmupSamples)
                }
            }
            levelTask?.cancel()
            levelTask = Task { [weak self] in
                for await level in levels {
                    guard let self, self.state.isRecording else { return }
                    self.state = .recording(level: level)
                }
            }
            maxDurationTask?.cancel()
            maxDurationTask = Task { [weak self, maximumDuration] in
                try? await Task.sleep(for: maximumDuration)
                guard let self, !Task.isCancelled, self.state.isRecording else { return }
                // Lost key-up, not an intentional release: submitting would
                // send a message unattended, so never submit here.
                self.hotkeyReleased(submit: false)
            }
        } catch {
            fail(.microphone(detail: error.localizedDescription))
        }
    }

    /// Returns immediately; the transcription runs in `inFlight`. Presses that
    /// arrive while it runs are dropped by the `.idle` guard rather than queued.
    /// With `submit`, Return follows the pasted text.
    public func hotkeyReleased(submit: Bool = false) {
        guard state.isRecording else { return }
        levelTask?.cancel()
        maxDurationTask?.cancel()
        feedTask?.cancel()
        feedTask = nil
        // Before the state flip, so no further pass is queued ahead of the
        // real call.
        stopWarmupLoop()
        state = .transcribing
        // The partial was a picture of the recording, and the recording is
        // over. The only statement this feature adds to the release path, and
        // it runs before `recordingStopped`, so it is not even inside the
        // measured window.
        partialTranscript = nil
        // Before `recordingStopped`, so restoring the speakers is outside the
        // release-to-paste window the app measures, and detached so the paste
        // never waits on a CoreAudio call. Unconditional, not gated on the
        // setting: turning it off mid-recording must still put the device
        // back. With nothing muted this is two integer reads on an actor.
        if let outputMuter {
            Task.detached(priority: .utility) { await outputMuter.recordingEnded() }
        }
        onEvent(.recordingStopped)
        let engine = cycleEngine ?? loader.engine
        let fedSamples = fedSampleCount
        fedSampleCount = 0
        cycleEngine = nil
        inFlight = Task { [weak self] in
            guard let self else { return }
            let stopped = ContinuousClock.now
            let audio = await self.capture.stop()
            let captureStop = ContinuousClock.now - stopped
            await self.finish(audio, fedSamples: fedSamples, with: engine, submit: submit, captureStop: captureStop)
        }
    }

    private func finish(
        _ audio: CapturedAudio,
        fedSamples: Int,
        with engine: any TranscriptionEngine,
        submit: Bool,
        captureStop: Duration
    ) async {
        defer { drainPendingUnloads() }
        // Streaming engines were already fed `fedSamples` while recording;
        // only the tail came through `stop()`.
        let totalDuration = Double(fedSamples + audio.samples.count) / CapturedAudio.sampleRate
        guard totalDuration >= minimumDuration else {
            if let streaming = engine as? (any StreamingTranscriptionEngine) {
                await streaming.abandonUtterance()
            }
            becomeIdle()
            return
        }
        do {
            var timing = CycleTiming(captureStop: captureStop, engine: .zero, processing: .zero, insert: .zero)
            var started = ContinuousClock.now
            var transcript = try await transcribeCycle(tailSamples: audio.samples, with: engine)
            timing.engine = ContinuousClock.now - started
            // The streaming engine only ever saw the tail; the coordinator
            // knows the whole utterance.
            if transcript.audioDuration == 0 {
                transcript.audioDuration = totalDuration
            }
            lastTranscript = transcript
            let settings = self.settings
            started = ContinuousClock.now
            let processed = await pipeline
                .run(transcript.text, disabled: settings.disabledProcessors)
            timing.processing = ContinuousClock.now - started
            guard !processed.isEmpty else {
                becomeIdle()
                return
            }
            state = .inserting
            // Don't double the junction: a transcript that already ends in
            // whitespace (e.g. "Tidy whitespace" disabled) carries its own
            // separator, so appending another makes a double space.
            let needsSpace = settings.appendTrailingSpace && processed.last?.isWhitespace != true
            let final = needsSpace ? processed + " " : processed
            started = ContinuousClock.now
            let result = try await output.insert(final, submit: submit)
            timing.insert = ContinuousClock.now - started
            var inserted = transcript
            inserted.text = processed
            lastTranscript = inserted
            onEvent(.inserted(inserted, timing))
            if result == .copied { showCopied() } else { becomeIdle() }
        } catch {
            fail(DictationFailure(error))
        }
    }

    /// Idle if the engine can take another dictation, otherwise unavailable
    /// with the engine's own reason.
    private func becomeIdle() {
        switch engineStatus {
        case .ready: state = .idle
        case .failed(let failure): state = .unavailable(.engineFailed(failure))
        case .unloaded, .downloading, .loading: state = .unavailable(.loadingModel)
        }
    }

    /// Cancel an in-progress recording without transcribing.
    public func cancelRecording() async {
        guard state.isRecording else { return }
        levelTask?.cancel()
        maxDurationTask?.cancel()
        stopWarmupLoop()
        partialTranscript = nil
        // Same restore as at release, for the paths that never transcribe:
        // an interrupted chord, a hotkey change, `stop()`.
        if let outputMuter {
            Task.detached(priority: .utility) { await outputMuter.recordingEnded() }
        }
        becomeIdle()
        abandonStreaming()
        cycleEngine = nil
        let engine = loader.engine
        _ = await capture.stop()
        if let streaming = engine as? (any StreamingTranscriptionEngine) {
            await streaming.abandonUtterance()
        }
        drainPendingUnloads()
    }

    /// The text is on the clipboard but nothing pasted it, so say so for a
    /// moment before going idle. Not a busy state: a press cancels the hint
    /// and starts the next dictation.
    private func showCopied() {
        state = .copied
        transientResetTask?.cancel()
        let hold = copiedDisplayDuration ?? settings.overlayAnimationSpeed.copiedHoldDuration
        transientResetTask = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard let self, !Task.isCancelled, case .copied = self.state else { return }
            self.becomeIdle()
        }
    }

    private func fail(_ failure: DictationFailure) {
        lastError = failure
        state = .error(failure)
        onEvent(.failed(failure))
        transientResetTask?.cancel()
        transientResetTask = Task { [weak self, errorDisplayDuration] in
            try? await Task.sleep(for: errorDisplayDuration)
            guard let self, !Task.isCancelled, case .error = self.state else { return }
            self.becomeIdle()
        }
    }
}
