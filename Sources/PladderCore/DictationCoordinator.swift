import Foundation
import Observation

/// The push-to-talk state machine. Owns no I/O itself; everything is injected.
///
/// Flow: hotkey pressed -> capture starts -> hotkey released -> capture stops ->
/// engine transcribes -> pipeline processes -> (polish hotkey: model refines ->)
/// output inserts -> idle.
///
/// A press of the toggle chord, or a tap of a hybrid chord shorter than
/// `holdThreshold`, leaves the recording running with `isLatched` set until
/// the next press of any chord, Escape, or the cap. `HotkeyGestureTracker`
/// decides which; the coordinator only carries out what it says.
///
/// Escape is the cancel key while a recording is on, and only then: the
/// monitor is told at the start and the end of every recording.
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

    /// True from a polish-hotkey press until that cycle ends, so the overlay
    /// can keep the pill up across the release.
    public private(set) var willPolish = false

    /// True while a recording continues after its chord was let go: a toggle
    /// press or a hybrid tap. The overlay draws it differently so the user
    /// knows the microphone is still on.
    public private(set) var isLatched = false

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
    /// for the stored chord". Applies to the dictate chord only; the polish
    /// chord has no stand-in and is simply not registered when Carbon cannot
    /// take it. A toggle chord equal to the stored chord follows the
    /// override, so a stood-in hybrid key stays hybrid.
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
    /// Transcripts shorter than this are pasted as they are: the model cannot
    /// improve three words and would cost a second.
    public var minimumPolishWords = 4
    /// Recordings are cut off after this long. A release event can be lost for
    /// real, for example while a secure password field has focus and global
    /// monitors receive nothing, and this keeps the microphone from staying on.
    public var maximumDuration: Duration = .seconds(600)
    /// A hybrid chord released sooner than this after its press latches the
    /// recording; a later release stops it. Handy and VoiceInk use 300 to
    /// 500 ms.
    public var holdThreshold: Duration = .milliseconds(400)
    /// A press this soon after a release of the same chord is the keyboard
    /// bouncing, not the user. See `HotkeyGestureTracker`.
    public var bounceWindow: Duration = .milliseconds(50)
    /// Seeds the gesture tracker: every stopping release waits `bounceWindow`
    /// first. A real keyboard turns this on by bouncing once; tests turn it
    /// on here.
    public var deferReleases = false
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
    /// The polish hotkey's second pass. Nil where there is none, which makes
    /// the polish key a plain dictation.
    private let refiner: (any TranscriptRefiner)?
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
    /// Hold, toggle or hybrid: what each chord's press and release mean.
    /// Rebuilt with the monitor, never per dictation.
    private var gesture = HotkeyGestureTracker(modes: [:])
    /// Waits out the bounce window of a deferred release.
    private var settleTask: Task<Void, Never>?

    /// Wall-clock time of each stage between the hotkey release and the paste.
    public struct CycleTiming: Sendable, Equatable {
        public var captureStop: Duration
        public var engine: Duration
        public var processing: Duration
        public var insert: Duration
        /// Nil on the normal path; on a polish cycle the model's time, zero
        /// when the transcript was too short for it.
        public var polish: Duration?

        public init(
            captureStop: Duration,
            engine: Duration,
            processing: Duration,
            insert: Duration,
            polish: Duration? = nil
        ) {
            self.captureStop = captureStop
            self.engine = engine
            self.processing = processing
            self.insert = insert
            self.polish = polish
        }
    }

    public enum Event: Sendable {
        case recordingStarted
        case recordingStopped
        case inserted(Transcript, CycleTiming)
        case failed(DictationFailure)
        /// Escape ended the recording; nothing is transcribed. The app plays
        /// the stop sound so the user hears the microphone go off, unlike an
        /// interrupted press, which is silent by design.
        case recordingDiscarded
        /// The gesture tracker has seen a same-chord press inside the bounce
        /// window, and from now on holds every stopping release for
        /// `bounceWindow` first. Emitted once, so a felt delay has an
        /// explanation in the log.
        case keyboardBounceObserved
    }

    public init(
        settings: Settings,
        registry: EngineRegistry,
        capture: any AudioCapture,
        output: any TextOutput,
        outputMuter: (any OutputMuter)? = nil,
        refiner: (any TranscriptRefiner)? = nil,
        hotkeyMonitor: any HotkeyMonitor,
        makePipeline: @escaping @Sendable (Settings) -> ProcessorPipeline,
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
        settleTask?.cancel()
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
        if old.hotkey != settings.hotkey || old.submitKey != settings.submitKey
            || old.polishHotkey != settings.polishHotkey
            || old.toggleHotkey != settings.toggleHotkey {
            // The old key's release will never arrive on the new stream.
            // The submit key counts too: the restarted monitor would never
            // deliver the pending release for the old configuration. So does
            // the toggle key, which may also turn the key hybrid or back.
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
    /// The chord that started the current recording. Only its release or
    /// cancel ends the recording. Nil between cycles.
    private var cycleRole: HotkeyRole?

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
        startGesture()
        var chords: [HotkeyRole: Hotkey] = [.dictate: hotkeyOverride ?? settings.hotkey]
        if let toggle = separateToggleChord { chords[.toggle] = toggle }
        // A polish chord that is already another role's chord would fire both
        // trackers at once; the settings row says why it does nothing.
        let polish = settings.polishHotkey.canonical
        if !polish.isEmpty, !chords.values.contains(where: { $0.canonical == polish }) {
            chords[.polish] = settings.polishHotkey
        }
        let stream = hotkeyMonitor.start(chords: chords, submitKey: settings.submitKey)
        hotkeyTask = Task { [weak self] in
            for await tagged in stream {
                guard let self else { return }
                // When the key moved, not when this loop got to it: a press
                // waits here for the microphone to start.
                let at = tagged.instant ?? .now
                // Only the chord that started the recording may end it, and
                // the gesture tracker is what knows which one that is: with
                // nested chords the other tracker reports the hand-over as its
                // own release.
                switch tagged.event {
                case .pressed:
                    let wasDeferring = self.gesture.deferReleases
                    let outcome = self.gesture.pressed(tagged.role, at: at)
                    if self.gesture.deferReleases, !wasDeferring { self.onEvent(.keyboardBounceObserved) }
                    await self.act(outcome)
                case .released(let submit):
                    await self.act(self.gesture.released(tagged.role, submit: submit, at: at))
                // Another key went down right after the chord: the user typed
                // Cmd+C, not a dictation. Drop the audio without transcribing,
                // without a stop sound and without a timing line.
                case .cancelled:
                    await self.act(self.gesture.interrupted(tagged.role))
                // Escape while a recording is on: drop it, and say so.
                case .escape:
                    await self.escapePressed()
                }
            }
        }
    }

    /// A toggle chord equal to the push-to-talk chord, stored or standing in
    /// for it, is not a second chord but the hybrid mode of the first: two
    /// roles cannot share a chord, and a stand-in that replaces a hybrid
    /// chord keeps it hybrid.
    private var toggleIsHybrid: Bool {
        let toggle = settings.toggleHotkey.canonical
        guard !toggle.isEmpty else { return false }
        return toggle == settings.hotkey.canonical || toggle == hotkeyOverride?.canonical
    }

    /// The toggle chord when it is a chord of its own; nil when it is off or
    /// hybrid.
    private var separateToggleChord: Hotkey? {
        settings.toggleHotkey.isEmpty || toggleIsHybrid ? nil : settings.toggleHotkey
    }

    /// A fresh tracker for a fresh monitor session. A bounce seen before is
    /// remembered: the keyboard has not changed because the monitor did.
    private func startGesture() {
        settleTask?.cancel()
        settleTask = nil
        isLatched = false
        gesture = HotkeyGestureTracker(
            modes: [.dictate: toggleIsHybrid ? .hybrid : .hold, .polish: .hold, .toggle: .toggle],
            holdThreshold: holdThreshold,
            bounceWindow: bounceWindow,
            deferReleases: deferReleases || gesture.deferReleases
        )
    }

    /// Carries out what the gesture tracker decided.
    private func act(_ outcome: HotkeyGestureTracker.Outcome) async {
        if let settle = outcome.settle { armSettle(settle) }
        switch outcome.action {
        case .start(let role):
            await hotkeyPressed(role: role)
            // A press the state machine refused (engine loading, a cycle in
            // flight, a microphone that failed) must not leave the tracker
            // holding or latching a recording that never began.
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
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: settle.after)
            guard let self, !Task.isCancelled else { return }
            // A stale token, one a bounce overtook, is ignored by the tracker.
            await self.act(self.gesture.timerFired(token: settle.token))
        }
    }

    /// The recording ended, however: the gesture starts over and Escape is
    /// the system's again. Synchronous, and the monitor call only flips a
    /// flag or queues work on the main thread, so on the release path this
    /// costs nothing before `recordingStopped`.
    private func endGesture() {
        settleTask?.cancel()
        settleTask = nil
        gesture.reset()
        isLatched = false
        hotkeyMonitor.setCancelKeyEnabled(false)
    }

    /// Public so tests and a menu item can drive the state machine directly.
    /// `role` is the chord that was pressed; it decides what the dictation
    /// goes through at release.
    public func hotkeyPressed(role: HotkeyRole = .dictate) async {
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
        cycleRole = role
        willPolish = role == .polish
        partialTranscript = nil
        // Read once, at press: switching the style mid-recording must not
        // leave the loop half live, with nothing warming the engine.
        let live = settings.overlayStyle == .liveTranscript
        // Flip state before the await so the overlay reacts on key-down and a
        // second concurrent press cannot start capture twice.
        state = .recording(level: 0)
        // Escape cancels from here on, and while the microphone comes up.
        hotkeyMonitor.setCancelKeyEnabled(true)
        do {
            let levels = try await capture.start()
            guard state.isRecording else {
                // Cancelled or superseded while the mic was starting.
                willPolish = false
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
            // The model's load is the one cost this feature can hide: about
            // 700 ms cold, paid while the user is still speaking.
            if willPolish, let refiner {
                Task.detached(priority: .utility) { await refiner.prepare() }
            }
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
            willPolish = false
            endGesture()
            fail(.microphone(detail: error.localizedDescription))
        }
    }

    /// Returns immediately; the transcription runs in `inFlight`. Presses that
    /// arrive while it runs are dropped by the `.idle` guard rather than queued.
    /// With `submit`, Return follows the pasted text.
    public func hotkeyReleased(submit: Bool = false) {
        guard state.isRecording else { return }
        // Whatever ended it — the chord, a toggle press, the cap — a latched
        // recording is over and the next press starts a new one.
        endGesture()
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
        cycleRole = nil
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
        defer {
            drainPendingUnloads()
            willPolish = false
        }
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
            // The polish key's one branch; on the normal path it costs a Bool
            // read. A refiner that cannot help returns nil and the text goes
            // out as dictated.
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
            // Don't double the junction: a transcript that already ends in
            // whitespace (e.g. "Tidy whitespace" disabled) carries its own
            // separator, so appending another makes a double space.
            let needsSpace = settings.appendTrailingSpace && final.last?.isWhitespace != true
            let toInsert = needsSpace ? final + " " : final
            started = ContinuousClock.now
            let result = try await output.insert(toInsert, submit: submit)
            timing.insert = ContinuousClock.now - started
            var inserted = transcript
            inserted.text = final
            lastTranscript = inserted
            onEvent(.inserted(inserted, timing))
            if result == .copied { showCopied() } else { becomeIdle() }
        } catch {
            fail(DictationFailure(error))
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
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
        endGesture()
        levelTask?.cancel()
        maxDurationTask?.cancel()
        stopWarmupLoop()
        partialTranscript = nil
        willPolish = false
        // Same restore as at release, for the paths that never transcribe:
        // an interrupted chord, a hotkey change, `stop()`.
        if let outputMuter {
            Task.detached(priority: .utility) { await outputMuter.recordingEnded() }
        }
        becomeIdle()
        abandonStreaming()
        cycleEngine = nil
        cycleRole = nil
        let engine = loader.engine
        _ = await capture.stop()
        if let streaming = engine as? (any StreamingTranscriptionEngine) {
            await streaming.abandonUtterance()
        }
        drainPendingUnloads()
    }

    /// Escape while recording: drop the audio without transcribing and say
    /// so, before the microphone has finished stopping, so the stop sound is
    /// not late. Public so tests can drive it.
    public func escapePressed() async {
        guard state.isRecording else { return }
        onEvent(.recordingDiscarded)
        await cancelRecording()
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
