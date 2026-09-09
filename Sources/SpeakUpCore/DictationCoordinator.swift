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

    public var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }

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
    /// Minimum recording length worth transcribing. Taps shorter than this are
    /// treated as accidental.
    public var minimumDuration: TimeInterval = 0.3

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
        startHotkey()
        Task { try? await capture.warmUp() }
        loadEngine()
    }

    public func stop() {
        hotkeyTask?.cancel()
        hotkeyMonitor.stop()
        statusTask?.cancel()
        levelTask?.cancel()
    }

    public var engineDisplayName: String { engine.displayName }

    /// Re-run engine load, for example after a failed download.
    public func reloadEngine() {
        loadEngine()
    }

    private func loadEngine() {
        statusTask?.cancel()
        let engine = self.engine
        statusTask = Task { [weak self] in
            guard let self else { return }
            await self.pollStatus(of: engine, until: { $0.isReady || self.isFailed($0) })
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.load()
            } catch {
                self.setEngineStatus(.failed(message: error.localizedDescription))
                return
            }
            let status = await engine.status
            self.setEngineStatus(status)
        }
    }

    private func isFailed(_ status: EngineStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// Cheap polling of the engine's status while it loads, so the UI can show
    /// download progress without every engine needing to expose a stream.
    private func pollStatus(of engine: any TranscriptionEngine, until done: @escaping (EngineStatus) -> Bool) async {
        while !Task.isCancelled {
            let status = await engine.status
            setEngineStatus(status)
            if done(status) { return }
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
            startHotkey()
        }
        if old.engineID != settings.engineID, let next = registry.make(settings.engineID) {
            let previous = engine
            Task { await previous.unload() }
            engine = next
            state = .unavailable(reason: "Loading model")
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
                case .released: await self.hotkeyReleased()
                }
            }
        }
    }

    /// Public so tests and a menu item can drive the state machine directly.
    public func hotkeyPressed() async {
        guard case .idle = state else { return }
        guard engineStatus.isReady else { return }
        do {
            let levels = try await capture.start()
            state = .recording(level: 0)
            onEvent(.recordingStarted)
            levelTask?.cancel()
            levelTask = Task { [weak self] in
                for await level in levels {
                    guard let self, self.state.isRecording else { return }
                    self.state = .recording(level: level)
                }
            }
        } catch {
            fail("Microphone: \(error.localizedDescription)")
        }
    }

    public func hotkeyReleased() async {
        guard state.isRecording else { return }
        levelTask?.cancel()
        state = .transcribing
        onEvent(.recordingStopped)
        let audio = await capture.stop()

        guard audio.duration >= minimumDuration else {
            state = .idle
            return
        }

        do {
            let transcript = try await engine.transcribe(audio.samples)
            lastTranscript = transcript
            let settings = self.settings
            let processed = try await makePipeline(settings).run(transcript.text, disabled: settings.disabledProcessors)
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
        _ = await capture.stop()
        state = .idle
    }

    private func fail(_ message: String) {
        lastError = message
        state = .error(message: message)
        onEvent(.failed(message))
        errorResetTask?.cancel()
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, case .error = self.state else { return }
            self.state = self.engineStatus.isReady ? .idle : .unavailable(reason: "Model not loaded")
        }
    }
}
