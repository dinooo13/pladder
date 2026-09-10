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

    /// Cleanup backends the Processing tab's "Using" picker lists. The app
    /// registers Apple Intelligence at launch; another backend can be added
    /// here later without touching settings or the pipeline.
    let cleanupRegistry: CleanupRegistry

    /// Stand-ins for the Processing tab's dictionary and whitespace toggles.
    /// Their `id`/`displayName`/`detail` don't depend on live settings, so
    /// these placeholders are enough for the UI; `makePipeline` below rebuilds
    /// the real processors from the live settings on every dictation.
    let dictionaryProcessor: any TextProcessor = DictionaryReplacer(entries: [])
    let whitespaceProcessor: any TextProcessor = WhitespaceNormalizer()

    /// `nil` when the selected cleanup provider is usable, otherwise the
    /// reason shown under the "Using" picker.
    var cleanupAvailability: String? {
        cleanupRegistry.entry(for: settings.cleanupProviderID)?.availability()
    }

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
        #if DEBUG
        registry.register(
            EngineRegistry.Entry(
                id: EchoEngine.engineID,
                displayName: "Echo (testing)",
                detail: "Returns fixed text, for testing",
                make: { EchoEngine() }
            )
        )
        #endif
        self.registry = registry

        // Cleanup backends, mirroring the engine registry above. Apple
        // Intelligence cleanup is opt-in: it adds about a second, so
        // `cleanupEnabled` defaults to false until the tidy pass has been
        // reviewed with the CLI harness.
        var mutableCleanupRegistry = CleanupRegistry()
        mutableCleanupRegistry.register(
            CleanupRegistry.Entry(
                id: FoundationModelProcessor.processorID,
                displayName: "Apple Intelligence",
                detail: "Adds punctuation, fixes capitalisation and drops filler sounds. About a second. Runs on device.",
                availability: { FoundationModelProcessor.availability },
                make: { FoundationModelProcessor() }
            )
        )
        // Captured by the `@Sendable` closure below, so pin it to a `let`
        // before self exists.
        let cleanupRegistry = mutableCleanupRegistry
        self.cleanupRegistry = cleanupRegistry

        let store = SettingsStore(
            url: Self.settingsURL,
            defaults: Settings(engineID: FluidAudioEngine.engineID)
        )
        self.store = store

        let events = self.events
        coordinator = DictationCoordinator(
            settings: store.load(),
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            makePipeline: { s in ProcessorPipeline.standard(settings: s, cleanup: cleanupRegistry) },
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
        startPermissionMirroring()
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

    /// Polls permission status every 2s until both Accessibility and
    /// Microphone are granted, then stops. Neither API offers a change
    /// notification, so this is how the menu and settings window notice a
    /// permission flipped in System Settings. Re-armed by
    /// `grantAccessibility()` and `grantMicrophone()` so a later revoke is
    /// picked up again.
    private func startPermissionMirroring() {
        refreshPermissions()
        guard needsAnyPermission else {
            permissionTask?.cancel()
            return
        }
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshPermissions()
                if !self.needsAnyPermission { return }
            }
        }
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        startPermissionMirroring()
    }

    func grantMicrophone() {
        Task { [weak self] in
            if Permissions.microphoneStatus == .notDetermined {
                _ = await Permissions.requestMicrophone()
            } else {
                Permissions.openMicrophoneSettings()
            }
            self?.refreshPermissions()
            self?.startPermissionMirroring()
        }
    }

    /// Set when `setLaunchAtLogin` fails, so settings can show the reason
    /// under the toggle. `LaunchAtLogin.isEnabled` is the source of truth for
    /// the toggle itself, since it can be changed behind the app's back in
    /// System Settings.
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
            settings.launchAtLogin = enabled
        } catch {
            launchAtLoginError = error.localizedDescription
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
