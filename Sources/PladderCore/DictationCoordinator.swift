import Foundation
import Observation

/// The push-to-talk state machine. Owns no I/O itself; everything is injected.
///
/// Flow: hotkey pressed -> capture starts -> hotkey released -> capture stops ->
/// engine transcribes -> pipeline processes -> (polish setting: model refines ->)
/// output inserts -> idle.
///
/// A press of the toggle chord, or a tap of a hybrid chord shorter than
/// `holdThreshold`, leaves the recording running with `isLatched` set until
/// the next press of any chord, Escape, or the cap. `HotkeyGestureTracker`
/// decides which; the coordinator only carries out what it says.
///
/// Escape is the cancel key while a recording is on, and only then: the
/// monitor is told at the start and the end of every recording.
///
/// Every wait goes through `clock`, so tests drive the timers instead of
/// sleeping through them. Event instants come from the monitors and the
/// wall clock; only the waiting is the clock's.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var state: DictationState = .unavailable(.starting)
    public private(set) var engineStatus: EngineStatus = .unloaded
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastError: DictationFailure?
    /// The microphone's level while recording, 0...1, for the meters. Zero
    /// otherwise.
    public private(set) var inputLevel: Float = 0

    /// What the engine makes of the recording so far, for the Live Transcript
    /// overlay. Display only: it is never processed and never inserted, and it
    /// is cleared the moment the key is released. Nil in every other style.
    public private(set) var partialTranscript: String?

    /// True when the current dictation is on its way through the refiner, so
    /// the overlay can keep the pill up across the release. Read off
    /// `settings.polishDictations` at key-down, so flipping the setting
    /// mid-recording cannot change this cycle.
    public private(set) var willPolish = false

    /// True while a recording continues after its chord was let go: a toggle
    /// press or a hybrid tap. The overlay draws it differently so the user
    /// knows the microphone is still on.
    public private(set) var isLatched = false

    /// The transcribe → process → insert work for the most recent release.
    /// Exposed so callers (and tests) can await completion of a cycle.
    public private(set) var inFlight: Task<Void, Never>?

    /// The app hands over a new value only when it differs; see
    /// `DictationSettings`. Setting it is `update` with the stand-in left as
    /// it is.
    public var settings: DictationSettings {
        get { currentSettings }
        set { update(newValue, hotkeyOverride: hotkeyOverride) }
    }
    private var currentSettings: DictationSettings

    /// True while the settings window is recording a new chord. The monitor
    /// is taken down so the keys the user presses to define the new hotkey
    /// cannot fire the old one, and a recording in progress is dropped.
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

    /// The chord the monitor listens for in place of `settings.hotkey`.
    ///
    /// Set by the app while Accessibility is missing and the stored chord
    /// cannot be registered without it — a modifier-only chord such as Right
    /// Command, which the default Option+Space then stands in for. The stored
    /// chord is left untouched and comes back the moment this is cleared,
    /// which is what happens when Accessibility is granted. Nil means "listen
    /// for the stored chord". Applies to the dictate chord only; a toggle
    /// chord equal to the stored chord follows the override, so a stood-in
    /// hybrid key stays hybrid. Setting it is `update` with the settings
    /// left as they are.
    public var hotkeyOverride: Hotkey? {
        get { currentHotkeyOverride }
        set { update(settings, hotkeyOverride: newValue) }
    }
    private var currentHotkeyOverride: Hotkey?

    /// Hands over the settings, the stand-in chord and, when it changes, the
    /// monitor together, so a chord change that also changes the stand-in or
    /// the monitor restarts the monitor once, with all of them. Set one after
    /// the other, the first restart would register the new chord with the
    /// old stand-in or on the old monitor: without Accessibility, or under
    /// Secure Event Input, a modifier-only chord that Carbon refuses, on its
    /// way to being stood in for or handed to the tap.
    public func update(
        _ settings: DictationSettings, hotkeyOverride: Hotkey?, monitor: (any HotkeyMonitor)? = nil
    ) {
        let old = currentSettings
        // The submit key counts: the restarted monitor would never deliver
        // the pending release for the old configuration. So does the toggle
        // key, which may also turn the key hybrid or back.
        let restart = monitor != nil || hotkeyOverride != currentHotkeyOverride
            || old.hotkey != settings.hotkey || old.submitKey != settings.submitKey
            || old.toggleHotkey != settings.toggleHotkey
        currentSettings = settings
        currentHotkeyOverride = hotkeyOverride
        if let monitor {
            stopHotkey()
            hotkeyMonitor = monitor
        }
        // Rebuilt here so that no processor is constructed on the
        // release-to-paste path, and only when the dictionary changed: it is
        // the one setting the processors are built from, and each build
        // compiles a regex per entry.
        if old.dictionary != settings.dictionary { pipeline = makePipeline(settings) }
        if restart { hotkeyConfigurationChanged() }
        if old.engineID != settings.engineID { engineChanged() }
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

    /// How long the Neural Engine is left idle between warm passes. One pass
    /// at key-down is not enough for a long dictation: on an M1 a pass after
    /// ten seconds of idle costs about 110 ms more than one made back to back,
    /// and that is larger than the capture stop, the processors and the paste
    /// together.
    public var warmupInterval: Duration = .seconds(2)

    /// How often the Live Transcript style asks the engine what it has heard
    /// so far. A live pass costs what a warm pass costs, so this is the warm
    /// interval with a much shorter fuse: four times a second of Neural Engine
    /// time buys text that keeps up with the speaker, at the price of a
    /// release being more likely to land inside a pass.
    public var livePassInterval: Duration = .milliseconds(500)

    /// How often the other styles hand captured audio to a streaming engine,
    /// so it confirms windows before release. A second of audio is cheap to
    /// copy and far shorter than the engine's 15 s window.
    public var feedInterval: Duration = .seconds(1)

    private let loader: EngineLoader
    private let capture: any AudioCapture
    private let output: any TextOutput
    /// Silences the speakers while the mic is open, when the setting is on.
    /// Nil in tests and wherever the app does not want the behaviour at all.
    private let outputMuter: (any OutputMuter)?
    /// The polish setting's second pass. Nil where there is none, which makes
    /// the polish a no-op.
    private let refiner: (any TranscriptRefiner)?
    private var hotkeyMonitor: any HotkeyMonitor
    /// Builds the processors from `dictionary`, the only setting they are
    /// built from; called again only when that changes.
    private let makePipeline: @Sendable (DictationSettings) -> ProcessorPipeline
    /// Rebuilt when settings change so that no processor is constructed on the
    /// release-to-paste path; `DictionaryReplacer` compiles a regex per entry.
    private var pipeline: ProcessorPipeline
    private let clock: any Clock<Duration>
    private let onEvent: @Sendable (Event) -> Void

    /// Set by `start()`. Before it nothing listens, so a monitor swap or a
    /// chord change made while the app is still setting up costs nothing,
    /// and `start()` registers what is current by then, once.
    private var isStarted = false
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

    /// Engines replaced by a settings change while a cycle was still running.
    /// Unloaded when the cycle ends.
    private var pendingUnloads: [any TranscriptionEngine] = []

    /// The engine that was ready when the current recording started. Nil
    /// between cycles.
    private var cycleEngine: (any TranscriptionEngine)?

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

    /// The current recording's utterance on a streaming engine, and the
    /// task that feeds it and returns how many samples it handed over; the
    /// tail from `stop()` completes the utterance at release. Nil for a batch
    /// engine, and for a streaming one that could not begin an utterance:
    /// that recording is transcribed whole at release instead of lost.
    private var stream: Stream?

    private struct Stream {
        let engine: any StreamingTranscriptionEngine
        let utterance: Utterance
        let feed: Task<Int, Never>
    }

    /// Numbers recordings. A press that waited for the microphone or the
    /// engine checks it is still its own recording before going on, and the
    /// output muter matches the end of one to its start with it, whichever
    /// order the two arrive in.
    private var recording = 0
    /// The tail of the last cancelled recording: the microphone stopping and
    /// the engine dropping the utterance. Each one waits for the one before
    /// it, so a press that comes before it is done waits for every earlier
    /// cancel, and its microphone and utterance start only after theirs have
    /// stopped.
    private var cancelCleanup: Task<Void, Never>?
    /// The mute that was armed at key-down and the restore that undoes it,
    /// kept so quitting can wait for the speakers to come back.
    private var muteRestoreTask: Task<Void, Never>?

    /// Half a second of silence. Transcribing it at key-down brings the
    /// Neural Engine up from idle while the user is still speaking; every
    /// utterance is padded to the model's full window, so this is the same
    /// encoder pass the real call makes.
    private static let warmupSamples = [Float](repeating: 0, count: 8_000)

    /// Hotkey events the loop has finished acting on. Internal, for tests
    /// that need to know an event was seen before they assert that it did
    /// nothing.
    @ObservationIgnored private(set) var handledHotkeyEvents = 0

    /// Wall-clock time of each stage between the hotkey release and the paste.
    public struct CycleTiming: Sendable, Equatable {
        public var captureStop: Duration
        public var engine: Duration
        public var processing: Duration
        public var insert: Duration
        /// Nil on the normal path; on a polish cycle the model's time, zero
        /// when the transcript was too short for it.
        public var polish: Duration?
    }

    /// What reached the output at the end of a cycle.
    public struct Insertion: Sendable, Equatable {
        /// `text` is what went out, after processing and polish, without the
        /// trailing space.
        public var transcript: Transcript
        public var timing: CycleTiming
        /// Pasted into the front app, or only left on the clipboard.
        public var result: InsertResult
        /// Return followed the paste, so the field was sent and emptied.
        public var submitted: Bool
    }

    public enum Event: Sendable {
        case recordingStarted
        case recordingStopped
        case inserted(Insertion)
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
        currentSettings = settings
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

    /// Loads the engine, warms the mic, and starts listening for the hotkey.
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

    /// The app is quitting. Stops listening, drops a recording in progress,
    /// lets a dictation already on its way out finish, and gives back what
    /// was borrowed — the speakers and the clipboard — before it returns.
    /// The app waits for this, with a deadline of its own.
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

    /// Re-run engine load, for example after a failed download.
    public func reloadEngine() {
        loader.load()
    }

    /// Swaps the hotkey source, for example when Accessibility is granted or
    /// revoked and the app moves between the event tap and Carbon.
    public func replaceHotkeyMonitor(_ monitor: any HotkeyMonitor) {
        update(settings, hotkeyOverride: hotkeyOverride, monitor: monitor)
    }

    private func setEngineStatus(_ status: EngineStatus) {
        engineStatus = status
        if status.isReady {
            if case .unavailable = state { becomeIdle() }
        } else if !state.isBusy {
            becomeIdle()
        }
    }

    private func engineChanged() {
        if let previous = loader.select(settings.engineID) {
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

    private func drainPendingUnloads() {
        guard !pendingUnloads.isEmpty else { return }
        let engines = pendingUnloads
        pendingUnloads = []
        Task {
            for engine in engines { await engine.unload() }
        }
    }

    // MARK: Hotkey

    /// The chords, the send key or the monitor changed. A release from the
    /// old configuration can never arrive on the new stream, so a recording
    /// in progress is dropped, and the monitor starts over unless it is
    /// suspended or the coordinator has not started yet.
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

    /// Cancels a recording in progress from a synchronous context. The
    /// recording ends here, before the caller starts a new monitor, so a
    /// press on the new stream finds the machine idle and waits only for the
    /// microphone to stop; ended from a task, it could find `.recording`
    /// still set and be refused.
    private func dropRecording() {
        guard let cleanup = beginCancel() else { return }
        Task {
            await cleanup.value
            drainPendingUnloads()
        }
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
        // When the key moved, not when this loop got to it: a press waits
        // here for the microphone to start.
        let at = tagged.instant ?? .now
        // Only the chord that started the recording may end it, and the
        // gesture tracker is what knows which one that is: with nested
        // chords the other tracker reports the hand-over as its own release.
        switch tagged.kind {
        case .chord(let role, .pressed):
            let wasDeferring = gesture.deferReleases
            let outcome = gesture.pressed(role, at: at)
            if gesture.deferReleases, !wasDeferring { onEvent(.keyboardBounceObserved) }
            await act(outcome)
        case .chord(let role, .released(let submit)):
            await act(gesture.released(role, submit: submit, at: at))
        // Another key went down right after the chord: the user typed Cmd+C,
        // not a dictation. Drop the audio without transcribing, without a
        // stop sound and without a timing line.
        case .chord(let role, .cancelled):
            await act(gesture.interrupted(role))
        // Escape while a recording is on: drop it, and say so.
        case .escape:
            await escapePressed()
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
            modes: [.dictate: toggleIsHybrid ? .hybrid : .hold, .toggle: .toggle],
            holdThreshold: holdThreshold,
            bounceWindow: bounceWindow,
            deferReleases: deferReleases || gesture.deferReleases
        )
    }

    /// Carries out what the gesture tracker decided.
    private func act(_ outcome: HotkeyGestureTracker.Outcome) async {
        if let settle = outcome.settle { armSettle(settle) }
        switch outcome.action {
        case .start:
            await hotkeyPressed()
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
        settleTask = Task { [weak self, clock] in
            try? await clock.sleep(for: settle.after)
            guard let self, !Task.isCancelled else { return }
            // A stale token, one a bounce overtook, is ignored by the tracker.
            await self.act(self.gesture.timerFired(token: settle.token))
        }
    }

    // MARK: Recording

    /// Public so tests and a menu item can drive the state machine directly.
    /// Which chord pressed, and so which may end the recording, is the
    /// gesture tracker's business, not the coordinator's.
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
        willPolish = settings.polishDictations
        partialTranscript = nil
        // Read once, at press: switching the style mid-recording must not
        // leave the loop half live, with nothing warming the engine.
        let live = settings.liveTranscript
        // Flip state before the await so the overlay reacts on key-down and a
        // second concurrent press cannot start capture twice.
        state = .recording
        inputLevel = 0
        recording += 1
        let mine = recording
        // Escape cancels from here on, and while the microphone comes up.
        hotkeyMonitor.setCancelKeyEnabled(true)
        // Normally long finished: only a press right on the heels of a cancel
        // waits here.
        await cancelCleanup?.value
        // Cancelled while it waited. A newer recording, if one has started
        // since, owns the microphone; starting it again would restart theirs.
        guard isCurrent(mine) else { return }
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
            // Cancelled while the mic was starting; the cancel has already
            // ended the recording, but the microphone came up after its stop.
            // A newer recording, if one has started since, owns it now.
            if !state.isRecording { _ = await capture.stop() }
            return
        }
        onEvent(.recordingStarted)
        armOutputMute()
        startKeyDownWork()
        await startEngineWork(live: live, recording: mine)
        // The utterance may have been cancelled while it began.
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
            // Lost key-up, not an intentional release: submitting would
            // send a message unattended, so never submit here.
            self.hotkeyReleased(submit: false)
        }
    }

    /// Work that keeps the release-to-paste path short, all of it run while
    /// the user is still speaking: the clipboard snapshot and the polish
    /// model's load, about 700 ms cold.
    private func startKeyDownWork() {
        Task { [weak self] in await self?.output.prepare() }
        if willPolish, let refiner {
            Task.detached(priority: .utility) { await refiner.prepare() }
        }
    }

    /// True while recording number `id` is the one in progress.
    private func isCurrent(_ id: Int) -> Bool {
        state.isRecording && recording == id
    }

    /// Starts streaming into the cycle's engine, or keeps a batch engine
    /// warm. A streaming engine that cannot begin an utterance is used like a
    /// batch engine for this recording: transcribed whole at release, slower
    /// but not lost.
    private func startEngineWork(live: Bool, recording id: Int) async {
        if let streaming = cycleEngine as? (any StreamingTranscriptionEngine),
           let utterance = try? await streaming.beginUtterance() {
            guard isCurrent(id) else {
                // Cancelled while it began. The handle names this
                // recording's utterance only, so a newer recording's is safe.
                await streaming.abandonUtterance(utterance)
                return
            }
            startStreamingFeed(streaming, utterance: utterance, live: live)
            // The live loop's pass is the warm pass, so a second loop would
            // only compete with it for the Neural Engine.
            if !live { startWarmupLoop { await streaming.warmPass() } }
        } else if let engine = cycleEngine {
            startWarmupLoop { [warmupSamples = Self.warmupSamples] in
                _ = try? await engine.transcribe(warmupSamples)
            }
        }
    }

    /// Hands captured audio to the engine while the user is still speaking,
    /// so the windowed engine confirms windows before release.
    ///
    /// In `live` mode the same loop also asks the engine for the text so far
    /// and publishes it, on the `livePassInterval` cadence. One loop and not
    /// two: two would drain the same chunks against each other, and a live
    /// pass could overlap the next one.
    ///
    /// At release the loop is cancelled and the release waits for it to
    /// exit. A chunk it drained just before the release is still handed
    /// over, so every sample reaches the engine once and in order, and
    /// nothing new — no further drain and no live pass — starts after it.
    private func startStreamingFeed(_ engine: any StreamingTranscriptionEngine, utterance: Utterance, live: Bool) {
        let feed = Task { [weak self, clock, feedInterval, livePassInterval] in
            var fed = 0
            while !Task.isCancelled {
                if !live { try? await clock.sleep(for: feedInterval) }
                guard let self, !Task.isCancelled, self.state.isRecording else { return fed }
                let chunk = await self.capture.drain()
                if !chunk.isEmpty {
                    fed += chunk.count
                    await engine.feed(chunk, to: utterance)
                }
                guard live, !Task.isCancelled else { continue }
                let text = await engine.livePass(utterance)
                // A pass that finishes after the release belongs to a
                // recording that is already on its way to the clipboard;
                // publishing it would put stale text back on screen.
                guard !Task.isCancelled, self.state.isRecording else { return fed }
                self.partialTranscript = text
                try? await clock.sleep(for: livePassInterval)
            }
            return fed
        }
        stream = Stream(engine: engine, utterance: utterance, feed: feed)
    }

    /// Warms once immediately, so a short dictation still gets the key-down
    /// pass, then keeps warming until cancelled. Detached and at utility
    /// priority so it never competes with the feed or the UI.
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

    /// Mutes the speakers for this recording when the setting is on. Read at
    /// press, so flipping the setting mid-recording cannot arm a mute half
    /// way through. The muter waits out its own delay before touching
    /// anything, so this is off the key-down path too.
    private func armOutputMute() {
        guard settings.muteOutputWhileDictating, let outputMuter else { return }
        let session = recording
        Task { await outputMuter.recordingStarted(session: session) }
    }

    /// Puts the speakers back. Unconditional, not gated on the setting:
    /// turning it off mid-recording must still restore the device, and with
    /// nothing muted this is two integer reads on an actor. Detached so the
    /// paste never waits on a CoreAudio call. The session number lets the
    /// muter match this to its start whichever arrives first.
    private func restoreOutputDevice() {
        guard let outputMuter else { return }
        let session = recording
        let previous = muteRestoreTask
        muteRestoreTask = Task.detached(priority: .utility) {
            await previous?.value
            await outputMuter.recordingEnded(session: session)
        }
    }

    /// Everything that ends a recording, however it ends: the gesture starts
    /// over, Escape is the system's again, the meter, cap, warm-up and feed
    /// stop, the partial is cleared and the speakers are put back.
    /// Synchronous, and every call in it only flips a flag, cancels a task or
    /// spawns one, so on the release path this costs nothing before
    /// `recordingStopped`.
    @discardableResult
    private func endRecording() -> Stream? {
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
        let ended = stream
        ended?.feed.cancel()
        stream = nil
        // Before the state flip, so no further pass is queued ahead of the
        // real call.
        warmupTask?.cancel()
        warmupTask = nil
        partialTranscript = nil
        restoreOutputDevice()
        return ended
    }

    /// Returns immediately; the transcription runs in `inFlight`. Presses that
    /// arrive while it runs are dropped by the `.idle` guard rather than queued.
    /// With `submit`, Return follows the pasted text.
    public func hotkeyReleased(submit: Bool = false) {
        guard state.isRecording else { return }
        // Whatever ended it — the chord, a toggle press, the cap — a latched
        // recording is over and the next press starts a new one.
        let stream = endRecording()
        state = .transcribing
        // Anything the user copied while speaking is snapshotted now, beside
        // the engine pass, rather than inside the paste.
        Task { [weak self] in await self?.output.prepare() }
        onEvent(.recordingStopped)
        let engine = cycleEngine ?? loader.engine
        cycleEngine = nil
        inFlight = Task { [weak self] in
            guard let self else { return }
            // The feed loop finishes handing over a chunk it drained before
            // the release, then exits; usually it is asleep and this is one
            // hop. What it does wait for is engine work `endUtterance` would
            // have waited for anyway, so it counts as engine time.
            let handover = ContinuousClock.now
            let fed = await stream?.feed.value
            let stopped = ContinuousClock.now
            let feedWait = stopped - handover
            let audio = await self.capture.stop()
            let captureStop = ContinuousClock.now - stopped
            await self.finish(
                audio, stream: stream, fedSamples: fed ?? 0, with: engine, submit: submit,
                captureStop: captureStop, feedWait: feedWait)
        }
    }

    private func finish(
        _ audio: CapturedAudio,
        stream: Stream?,
        fedSamples: Int,
        with engine: any TranscriptionEngine,
        submit: Bool,
        captureStop: Duration,
        feedWait: Duration
    ) async {
        defer {
            drainPendingUnloads()
            willPolish = false
        }
        // Streaming engines were already fed `fedSamples` while recording;
        // only the tail came through `stop()`.
        let totalDuration = Double(fedSamples + audio.samples.count) / CapturedAudio.sampleRate
        guard totalDuration >= minimumDuration else {
            if let stream { await stream.engine.abandonUtterance(stream.utterance) }
            becomeIdle()
            return
        }
        do {
            var timing = CycleTiming(captureStop: captureStop, engine: .zero, processing: .zero, insert: .zero)
            var started = ContinuousClock.now
            var transcript = if let stream {
                try await stream.engine.endUtterance(stream.utterance, tail: audio.samples)
            } else {
                try await engine.transcribe(audio.samples)
            }
            timing.engine = feedWait + (ContinuousClock.now - started)
            // The streaming engine only ever saw the tail; the coordinator
            // knows the whole utterance.
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
            // The polish setting's one branch; off, it costs a Bool read.
            // A refiner that cannot help returns nil and the text goes
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

    /// Idle if the engine can take another dictation, otherwise unavailable
    /// with the engine's own reason.
    private func becomeIdle() {
        switch engineStatus {
        case .ready: state = .idle
        case .failed(let failure): state = .unavailable(.engineFailed(failure))
        case .unloaded, .downloading, .loading: state = .unavailable(.loadingModel)
        }
    }

    /// Cancel an in-progress recording without transcribing. Covers the paths
    /// that never transcribe: an interrupted chord, Escape, a hotkey change,
    /// `stop()`.
    public func cancelRecording() async {
        guard let cleanup = beginCancel() else { return }
        await cleanup.value
        drainPendingUnloads()
    }

    /// The synchronous half of a cancel: the recording is over and the state
    /// idle when this returns. The returned task stops the microphone and
    /// drops the utterance; nil when nothing was recording.
    private func beginCancel() -> Task<Void, Never>? {
        guard state.isRecording else { return nil }
        let stream = endRecording()
        willPolish = false
        becomeIdle()
        cycleEngine = nil
        // The microphone goes off first. The engine drops the utterance only
        // once the feed is out of the way, so no chunk lands after it. Then
        // the cancel before this one, still under way, is waited for, so
        // whoever waits for this one waits for both.
        let previous = cancelCleanup
        let cleanup = Task { [capture] in
            _ = await capture.stop()
            if let stream {
                _ = await stream.feed.value
                await stream.engine.abandonUtterance(stream.utterance)
            }
            await previous?.value
        }
        cancelCleanup = cleanup
        return cleanup
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
