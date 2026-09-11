import AppKit
import AVFoundation
import Foundation
import Observation
import SpeakUpCore
import os

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

    /// Text processors in pipeline order. The single source of truth for both
    /// the settings toggles (ids, display names, details) and the runtime
    /// pipeline `makePipeline` builds below.
    let processors: [any TextProcessor]

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

    /// When the hotkey was released, for the release-to-paste measurement.
    private var releaseInstant: ContinuousClock.Instant?
    /// Release-to-paste time per dictation, the number the user feels. Read
    /// it with: log show --last 1h --predicate 'subsystem == "de.speakup.app"'
    private static let timing = Logger(subsystem: "de.speakup.app", category: "timing")

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

        let store = SettingsStore(
            url: Self.settingsURL,
            defaults: Settings(engineID: FluidAudioEngine.engineID)
        )
        self.store = store

        // Processors, in pipeline order: the dictionary runs first so its
        // output is what gets inserted, and whitespace is tidied last. This
        // is the single place that order is defined; both the settings
        // toggles and `makePipeline` below derive from it.
        // `DictionaryReplacer`'s entries here are unused placeholders — its
        // `id`/`displayName`/`detail` don't depend on them, and `makePipeline`
        // rebuilds it from the live settings on every dictation.
        let processorOrder: [any TextProcessor] = [
            DictionaryReplacer(entries: []),
            WhitespaceNormalizer(),
        ]
        self.processors = processorOrder

        let events = self.events
        coordinator = DictationCoordinator(
            settings: store.load(),
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            makePipeline: { s in
                ProcessorPipeline(processorOrder.map { processor in
                    processor.id == DictionaryReplacer.processorID
                        ? DictionaryReplacer(entries: s.dictionary)
                        : processor
                })
            },
            onEvent: { [events] event in events.send(event) }
        )

        overlay = OverlayController(coordinator: coordinator)
        events.handler = { [weak self] event, at in self?.handle(event, at: at) }
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

    private func handle(_ event: DictationCoordinator.Event, at instant: ContinuousClock.Instant) {
        switch event {
        case .recordingStarted:
            if settings.playSounds { SoundPlayer.playStart() }
        case .recordingStopped:
            releaseInstant = instant
            if settings.playSounds { SoundPlayer.playStop() }
        case .inserted(let transcript):
            guard let released = releaseInstant else { return }
            releaseInstant = nil
            let total = Self.seconds(instant - released)
            Self.timing.log(
                "release-to-paste \(total, format: .fixed(precision: 3), privacy: .public) s, audio \(transcript.audioDuration, format: .fixed(precision: 1), privacy: .public) s, engine \(transcript.processingTime, format: .fixed(precision: 3), privacy: .public) s"
            )
        case .failed:
            releaseInstant = nil
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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

    /// The app icon's waveform glyph, varied by state (see `MenuBarIcon`).
    var menuBarImage: NSImage {
        MenuBarIcon.image(for: coordinator.state)
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

    /// A short, word-boundary-aware summary of the most recent transcript for
    /// the menu; longer previews make the menu bar menu comically wide.
    var lastTranscriptSummary: String? {
        guard let text = coordinator.lastTranscript?.text, !text.isEmpty else { return nil }
        let limit = 32
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > 20 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }
}

/// Bridges the coordinator's nonisolated `onEvent` callback back onto the main
/// actor, and lets us hand the coordinator a callback before `self` exists.
///
/// Each event is stamped when the coordinator emits it, not when the main
/// actor gets around to handling it, so the release-to-paste measurement does
/// not include scheduling delay.
@MainActor
final class EventRelay {
    var handler: ((DictationCoordinator.Event, ContinuousClock.Instant) -> Void)?

    nonisolated func send(_ event: DictationCoordinator.Event) {
        let at = ContinuousClock.now
        Task { @MainActor in self.handler?(event, at) }
    }
}
