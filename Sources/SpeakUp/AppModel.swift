import AVFoundation
import Foundation
import Observation
import SpeakUpCore

import SpeakUpSystem
import SpeakUpAudio
import SpeakUpEngines

/// Composition root. Builds the engine registry, the settings store and the
/// coordinator, owns the overlay, and exposes everything the UI needs.
@MainActor
@Observable
final class AppModel {
    let registry: EngineRegistry
    let coordinator: DictationCoordinator

    /// Mirrored permission state, refreshed on a timer so the menu and the
    /// settings window stay correct after the user flips a switch in System
    /// Settings (neither API offers a change notification).
    private(set) var accessibilityTrusted: Bool = Permissions.isAccessibilityTrusted
    private(set) var microphoneStatus: AVAuthorizationStatus = Permissions.microphoneStatus

    private let store: SettingsStore
    private let events = EventRelay()
    private let overlay: OverlayController
    private var permissionTask: Task<Void, Never>?
    private var didRequestAccessibility = false

    /// Settings live in the coordinator (it reacts to hotkey/engine changes);
    /// this forwards and persists.
    var settings: Settings {
        get { coordinator.settings }
        set {
            guard newValue != coordinator.settings else { return }
            coordinator.settings = newValue
            try? store.save(newValue)
        }
    }

    init() {
        // Engines, in the order the settings picker shows them. The first
        // entry is the default for new installs.
        var registry = EngineRegistry()
        registry.register(
            EngineRegistry.Entry(
                id: FluidAudioEngine.engineID,
                displayName: "Parakeet TDT v3",
                detail: "NVIDIA Parakeet via FluidAudio, runs on the Neural Engine. ~700 MB download on first use.",
                make: { FluidAudioEngine() }
            )
        )
        registry.register(
            EngineRegistry.Entry(
                id: EchoEngine.engineID,
                displayName: "Echo (testing)",
                detail: "Returns fixed text, for testing",
                make: { EchoEngine() }
            )
        )
        self.registry = registry

        let store = SettingsStore(
            url: Self.settingsURL,
            // Apple Intelligence cleanup is opt-in: it adds about a second.
            defaults: Settings(
                engineID: FluidAudioEngine.engineID,
                disabledProcessors: [FoundationModelProcessor.processorID]
            )
        )
        self.store = store

        let events = self.events
        coordinator = DictationCoordinator(
            settings: store.load(),
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            makePipeline: { s in
                // Order matters: the dictionary runs first so its output is what
                // the optional language model sees, and whitespace is tidied last.
                ProcessorPipeline([
                    DictionaryReplacer(entries: s.dictionary),
                    FoundationModelProcessor(),
                    WhitespaceNormalizer(),
                ])
            },
            onEvent: { [events] event in events.send(event) }
        )

        overlay = OverlayController(coordinator: coordinator)
        events.handler = { [weak self] event in self?.handle(event) }
    }

    static var settingsURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/SpeakUp/settings.json")
    }

    // MARK: Lifecycle

    func start() {
        refreshPermissions()
        if !accessibilityTrusted && !didRequestAccessibility {
            didRequestAccessibility = true
            Permissions.requestAccessibility()
        }
        overlay.start()
        coordinator.start()

        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }
    }

    func stop() {
        permissionTask?.cancel()
        overlay.stop()
        coordinator.stop()
    }

    private func handle(_ event: DictationCoordinator.Event) {
        guard settings.playSounds else { return }
        switch event {
        case .recordingStarted: SoundPlayer.playStart()
        case .recordingStopped: SoundPlayer.playStop()
        case .inserted, .failed: break
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        microphoneStatus = Permissions.microphoneStatus
    }

    var needsAccessibility: Bool { !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    func grantMicrophone() {
        Task { [weak self] in
            if Permissions.microphoneStatus == .notDetermined {
                _ = await Permissions.requestMicrophone()
            } else {
                Permissions.openMicrophoneSettings()
            }
            self?.refreshPermissions()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLogin = enabled
        } catch {
            settings.launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: Menu presentation

    var menuBarSymbol: String {
        switch coordinator.state {
        case .recording: "mic.fill"
        case .transcribing, .inserting: "waveform"
        case .unavailable, .error: "mic.slash"
        case .idle: "mic"
        }
    }

    /// One line describing what the app is doing right now.
    var statusLine: String {
        switch coordinator.state {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .error(let message): return "Error: \(message)"
        case .idle: return "Ready — hold \(settings.hotkey.displayName)"
        case .unavailable:
            switch coordinator.engineStatus {
            case .downloading(let progress):
                if let progress {
                    return "Model: downloading \(Int((progress * 100).rounded()))%"
                }
                return "Model: downloading…"
            case .loading: return "Model: loading…"
            case .unloaded: return "Model: not loaded"
            case .failed(let message): return "Model failed: \(message)"
            case .ready: return "Ready — hold \(settings.hotkey.displayName)"
            }
        }
    }

    var canRetryEngine: Bool {
        if case .failed = coordinator.engineStatus { return true }
        return false
    }

    /// First 60 characters of the most recent transcript, for the menu.
    var lastTranscriptSummary: String? {
        guard let text = coordinator.lastTranscript?.text, !text.isEmpty else { return nil }
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}

/// Bridges the coordinator's nonisolated `onEvent` callback back onto the main
/// actor, and lets us hand the coordinator a callback before `self` exists.
@MainActor
final class EventRelay {
    var handler: ((DictationCoordinator.Event) -> Void)?

    nonisolated func send(_ event: DictationCoordinator.Event) {
        Task { @MainActor in self.handler?(event) }
    }
}
