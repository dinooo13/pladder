import Foundation
import Observation

/// The push-to-talk state machine. Owns no I/O itself; everything is injected.
///
/// Flow: hotkey pressed -> capture starts -> hotkey released -> capture stops ->
/// engine transcribes -> pipeline processes -> output inserts -> idle.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var state: DictationState = .unavailable(reason: "Starting")
    public private(set) var engineStatus: EngineStatus = .unloaded
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastError: String?

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

    /// Minimum recording length worth transcribing. Taps shorter than this are
    /// treated as accidental.
    public var minimumDuration: TimeInterval = 0.3
    /// Recordings are cut off after this long. A release event can be lost for
    /// real, for example while a secure password field has focus and global
    /// monitors receive nothing, and this keeps the microphone from staying on.
    public var maximumDuration: Duration = .seconds(120)
    /// How long an error stays on screen before returning to idle.
    public var errorDisplayDuration: Duration = .seconds(2)

    private var engine: any TranscriptionEngine
    private let capture: any AudioCapture
    private let output: any TextOutput
    private let hotkeyMonitor: any HotkeyMonitor
    private let registry: EngineRegistry
    private let makePipeline: @Sendable (Settings) -> ProcessorPipeline
    private let onEvent: @Sendable (Event) -> Void

    private var hotkeyTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?

    public enum Event: Sendable {
        case recordingStarted
        case recordingStopped
        case inserted(Transcript)
        case failed(String)
    }

    public init(
        settings: Settings,
        registry: EngineRegistry,
        capture: any AudioCapture,
        output: any TextOutput,
        hotkeyMonitor: any HotkeyMonitor,
        makePipeline: @escaping @Sendable (Settings) -> ProcessorPipeline,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.settings = settings
        self.registry = registry
        self.capture = capture
        self.output = output
        self.hotkeyMonitor = hotkeyMonitor
        self.makePipeline = makePipeline
        self.onEvent = onEvent
        guard let engine = registry.make(settings.engineID) else {
            preconditionFailure("EngineRegistry has no engines")
        }
        self.engine = engine
    }

    // MARK: Lifecycle

    /// Loads the engine, warms the mic, and starts listening for the hotkey.
    public func start() {
        if !isHotkeySuspended { startHotkey() }
        Task { try? await capture.warmUp() }
        loadEngine()
    }

    public func stop() {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        statusTask?.cancel()
        levelTask?.cancel()
        errorResetTask?.cancel()
        maxDurationTask?.cancel()
        if state.isRecording {
            Task { await cancelRecording() }
        }
    }

    /// Re-run engine load, for example after a failed download.
    public func reloadEngine() {
        loadEngine()
    }

    private func loadEngine() {
        statusTask?.cancel()
        let engine = self.engine
        // The poll is the single writer of `engineStatus` while loading, so the
        // failure text always comes from the engine itself.
        statusTask = Task { [weak self] in
            guard let self else { return }
            await self.pollStatus(of: engine)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.load()
            } catch {
                let status = await engine.status
                if case .failed = status {
                    self.setEngineStatus(status)
                } else {
                    self.setEngineStatus(.failed(message: error.localizedDescription))
                }
                self.statusTask?.cancel()
                return
            }
            self.setEngineStatus(await engine.status)
            self.statusTask?.cancel()
        }
    }

    /// Cheap polling of the engine's status while it loads, so the UI can show
    /// download progress without every engine needing to expose a stream.
    private func pollStatus(of engine: any TranscriptionEngine) async {
        while !Task.isCancelled {
            let status = await engine.status
            guard !Task.isCancelled else { return }
            setEngineStatus(status)
            switch status {
            case .ready, .failed: return
            default: break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func setEngineStatus(_ status: EngineStatus) {
        engineStatus = status
        switch status {
        case .ready:
            if case .unavailable = state { state = .idle }
        case .failed(let message):
            if !state.isBusy { state = .unavailable(reason: message) }
        case .downloading, .loading, .unloaded:
            if !state.isBusy { state = .unavailable(reason: "Loading model") }
        }
    }

    private func settingsChanged(from old: Settings) {
        if old.hotkey != settings.hotkey {
            // The old key's release will never arrive on the new stream.
            if state.isRecording {
                Task { await cancelRecording() }
            }
            if !isHotkeySuspended { startHotkey() }
        }
        if old.engineID != settings.engineID, let next = registry.make(settings.engineID) {
            let previous = engine
            Task { await previous.unload() }
            engine = next
            engineStatus = .unloaded
            // Leave a recording or transcription alone; the poll moves the
            // state once the new engine reports.
            if !state.isBusy { state = .unavailable(reason: "Loading model") }
            loadEngine()
        }
    }

    // MARK: Hotkey

    private func startHotkey() {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        let stream = hotkeyMonitor.start(hotkey: settings.hotkey)
        hotkeyTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .pressed: await self.hotkeyPressed()
                case .released: self.hotkeyReleased()
                }
            }
        }
    }

    /// Public so tests and a menu item can drive the state machine directly.
    public func hotkeyPressed() async {
        guard case .idle = state else { return }
        guard engineStatus.isReady else { return }
        // Flip state before the await so the overlay reacts on key-down and a
        // second concurrent press cannot start capture twice.
        state = .recording(level: 0)
        do {
            let levels = try await capture.start()
            guard state.isRecording else {
                // Cancelled or superseded while the mic was starting.
                _ = await capture.stop()
                return
            }
            onEvent(.recordingStarted)
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
                self.hotkeyReleased()
            }
        } catch {
            fail("Microphone: \(error.localizedDescription)")
        }
    }

    /// Returns immediately; the transcription runs in `inFlight`. Presses that
    /// arrive while it runs are dropped by the `.idle` guard rather than queued.
    public func hotkeyReleased() {
        guard state.isRecording else { return }
        levelTask?.cancel()
        maxDurationTask?.cancel()
        state = .transcribing
        onEvent(.recordingStopped)
        inFlight = Task { [weak self] in
            guard let self else { return }
            let audio = await self.capture.stop()
            await self.finish(audio)
        }
    }

    private func finish(_ audio: CapturedAudio) async {
        guard audio.duration >= minimumDuration else {
            state = .idle
            return
        }
        do {
            let transcript = try await engine.transcribe(audio.samples)
            lastTranscript = transcript
            let settings = self.settings
            let processed = try await makePipeline(settings)
                .run(transcript.text, disabled: settings.disabledProcessors)
            guard !processed.isEmpty else {
                state = .idle
                return
            }
            state = .inserting
            let final = settings.appendTrailingSpace ? processed + " " : processed
            try await output.insert(final)
            var inserted = transcript
            inserted.text = processed
            lastTranscript = inserted
            onEvent(.inserted(inserted))
            state = .idle
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Cancel an in-progress recording without transcribing.
    public func cancelRecording() async {
        guard state.isRecording else { return }
        levelTask?.cancel()
        maxDurationTask?.cancel()
        state = .idle
        _ = await capture.stop()
    }

    private func fail(_ message: String) {
        lastError = message
        state = .error(message: message)
        onEvent(.failed(message))
        errorResetTask?.cancel()
        errorResetTask = Task { [weak self, errorDisplayDuration] in
            try? await Task.sleep(for: errorDisplayDuration)
            guard let self, !Task.isCancelled, case .error = self.state else { return }
            self.state = self.engineStatus.isReady ? .idle : .unavailable(reason: "Model not loaded")
        }
    }
}
