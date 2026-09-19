import AppKit
import AVFoundation
import Foundation
import Observation
import PladderCore
import os

import PladderSystem
import PladderAudio
import PladderEngines

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

    /// The keyboard shortcuts macOS itself handles. Read on explicit triggers
    /// only — launch, a permission flip, a hotkey edit, the settings window
    /// opening — because `CopySymbolicHotKeys` is main-thread work linear in
    /// the number of shortcuts and the answer changes about as often as
    /// someone visits System Settings. Never on a key press.
    private(set) var systemShortcuts: Set<Hotkey> = []

    /// The chord that stands in for the stored one while Accessibility is
    /// missing, or nil when the stored chord is what the monitor listens for.
    ///
    /// The stored chord is never rewritten: Right Command stays the default
    /// and comes back the moment an administrator ticks the box.
    private(set) var fallbackHotkey: Hotkey?

    /// So the first `refreshPermissions()` computes the stand-in even though
    /// nothing flipped; `hotkeyUsesTap` already matches the grant at that point.
    private var didComputeEffectiveHotkey = false

    private let store: SettingsStore
    private let events = EventRelay()
    private let overlay: OverlayController
    private var permissionTask: Task<Void, Never>?
    private var didRequestAccessibility = false

    /// Both hotkey sources, kept for the app's life so switching between them
    /// costs nothing. The tap swallows the chord's regular key and matches
    /// left and right modifiers exactly, but needs Accessibility; Carbon needs
    /// no permission at all and is what a standard account gets.
    private let tapHotkey = GlobalHotkeyMonitor()
    private let carbonHotkey = CarbonHotkeyMonitor()
    /// Which of the two the coordinator is currently driven by.
    private var hotkeyUsesTap: Bool

    /// When the hotkey was released, for the release-to-paste measurement.
    private var releaseInstant: ContinuousClock.Instant?
    /// Release-to-paste time per dictation, the number the user feels. Read
    /// it with: log show --last 1h --predicate 'subsystem == "de.dinooo13.pladder"'
    private static let timing = Logger(subsystem: "de.dinooo13.pladder", category: "timing")

    /// Settings live in the coordinator (it reacts to hotkey/engine changes);
    /// this forwards and persists. Applying the appearance covers every
    /// window and menu at once, so no view has to care.
    ///
    /// Each side effect runs only when its own keys changed. Re-assigning
    /// `NSApp.appearance` is not free: with a forced Light or Dark it makes
    /// AppKit re-theme every window, so doing it on every click of a settings
    /// card made the card rows lag behind the click.
    var settings: Settings {
        get { coordinator.settings }
        set {
            let old = coordinator.settings
            guard newValue != old else { return }
            coordinator.settings = newValue
            if newValue.appearance != old.appearance {
                applyAppearance(newValue.appearance)
            }
            if newValue.overlayStyle != old.overlayStyle || newValue.overlayGlass != old.overlayGlass {
                overlay.applyStyle(newValue.overlayStyle, glass: newValue.overlayGlass)
            }
            if newValue.hotkey != old.hotkey {
                // A chord with a regular key no longer needs a stand-in, and a
                // modifier-only one does.
                updateEffectiveHotkey()
            }
            try? store.save(newValue)
        }
    }

    private func applyAppearance(_ appearance: Appearance) {
        let resolved: NSAppearance? = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = resolved
        overlay.applyAppearance(appearance)
    }

    init() {
        // Engines, in the order the settings picker shows them. The first
        // entry is the default for new installs.
        var registry = EngineRegistry()
        registry.register(
            EngineRegistry.Entry(
                id: FluidAudioIncrementalEngine.engineID,
                displayName: "Parakeet TDT v3",
                detail: "NVIDIA Parakeet via FluidAudio, runs on the Neural Engine. ~700 MB download on first use.",
                make: { FluidAudioIncrementalEngine() }
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
            defaults: Settings(engineID: FluidAudioIncrementalEngine.engineID)
        )
        Self.migrateLegacySettings(to: Self.settingsURL)
        self.store = store

        // One read: the store moves an undecodable file aside on load, so a
        // second read could see different settings than the first.
        var initial = store.load()

        // An engine that was removed in an update leaves a stale ID behind.
        // `EngineRegistry.make` already falls back to the first entry, so the
        // app works either way; rewriting the ID keeps the settings picker
        // showing what is actually running.
        if registry.entry(for: initial.engineID) == nil,
            let fallback = registry.available.first {
            initial.engineID = fallback.id
        }

        // Processors, in pipeline order: fillers go first so the dictionary sees
        // cleaned text, and whitespace is tidied last. Each entry is a factory so
        // a processor that needs settings builds itself from them; nothing here
        // knows which processor that is.
        let processorFactories: [@Sendable (Settings) -> any TextProcessor] = [
            { _ in FillerRemover() },
            { DictionaryReplacer(entries: $0.dictionary) },
            { _ in WhitespaceNormalizer() },
        ]
        self.processors = processorFactories.map { $0(initial) }

        let events = self.events
        let trusted = Permissions.isAccessibilityTrusted
        hotkeyUsesTap = trusted
        coordinator = DictationCoordinator(
            settings: initial,
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            hotkeyMonitor: trusted ? tapHotkey : carbonHotkey,
            makePipeline: { s in ProcessorPipeline(processorFactories.map { $0(s) }) },
            onEvent: { [events] event in events.send(event) }
        )

        overlay = OverlayController(coordinator: coordinator)
        events.handler = { [weak self] event, at in self?.handle(event, at: at) }
    }

    static var settingsURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pladder/settings.json")
    }

    /// One-time migration from the pre-rename location. The dictionary and
    /// hotkey settings were kept in `~/Library/Application Support/SpeakUp/`
    /// before the app was called Pladder; copy them across exactly once, only
    /// when the new file does not exist yet. The old file is left in place.
    static func migrateLegacySettings(to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let legacy = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/SpeakUp/settings.json")
        try? FileManager.default.copyItem(at: legacy, to: destination)
    }

    // MARK: Lifecycle

    func start() {
        applyAppearance(settings.appearance)
        overlay.applyStyle(settings.overlayStyle, glass: settings.overlayGlass)
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
        func fmt(_ duration: Duration) -> String {
            let d = Self.seconds(duration)
            return String(format: "%.3f", d)
        }
        switch event {
        case .recordingStarted:
            if settings.playSounds { SoundPlayer.playStart() }
        case .recordingStopped:
            releaseInstant = instant
            if settings.playSounds { SoundPlayer.playStop() }
        case .inserted(let transcript, let timing):
            guard let released = releaseInstant else { return }
            releaseInstant = nil
            let total = Self.seconds(instant - released)
            let stages = "stop \(fmt(timing.captureStop)), engine \(fmt(timing.engine)), " +
                "process \(fmt(timing.processing)), paste \(fmt(timing.insert))"
            Self.timing.log(
                """
                release-to-paste \(total, format: .fixed(precision: 3), privacy: .public) s: \(stages, privacy: .public); \
                audio \(transcript.audioDuration, format: .fixed(precision: 1), privacy: .public) s, \
                engine-time \(transcript.processingTime, format: .fixed(precision: 3), privacy: .public) s
                """
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
        // Granting Accessibility upgrades the hotkey to the tap; revoking it
        // drops back to Carbon. Either way a recording in progress is dropped
        // by the coordinator, since the old monitor's release can no longer
        // arrive.
        let flipped = accessibilityTrusted != hotkeyUsesTap
        if flipped {
            hotkeyUsesTap = accessibilityTrusted
            coordinator.replaceHotkeyMonitor(accessibilityTrusted ? tapHotkey : carbonHotkey)
        }
        // After the swap: the new monitor is started with the old stand-in and
        // then, if it changed, once more with the new one. The other order
        // would make the Carbon monitor log a failure for Right Command on the
        // way to being replaced by the tap.
        if flipped || !didComputeEffectiveHotkey {
            didComputeEffectiveHotkey = true
            refreshSystemShortcuts()
        }
    }

    /// Re-reads the shortcuts macOS owns and recomputes the stand-in chord.
    /// Called when the settings window opens, the moment the answer is about
    /// to be shown to the user and the recorder about to be handed it.
    func refreshSystemShortcuts() {
        let shortcuts = SystemShortcuts.enabled()
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
        updateEffectiveHotkey()
    }

    /// The stand-in chord is a function of the stored chord, the Accessibility
    /// grant and the shortcuts macOS owns. With the grant there is none: the
    /// tap matches anything. Without it, a chord Carbon cannot register — or
    /// one the window server eats first — listens for nothing, so the first
    /// free candidate takes its place until the grant arrives.
    private func updateEffectiveHotkey() {
        let stored = settings.hotkey
        let standsIn = !accessibilityTrusted
            && (!stored.canBeRegisteredWithoutAccessibility
                || stored.systemShortcutConflict(in: systemShortcuts) != nil)
        let fallback = standsIn ? Hotkey.fallback(avoiding: systemShortcuts) : nil
        if fallback != fallbackHotkey { fallbackHotkey = fallback }
        coordinator.hotkeyOverride = fallback
    }

    /// The enabled macOS shortcut that swallows `hotkey`, if any. Shown as a
    /// warning in both modes: the tap sees such a chord, but the system
    /// shortcut fires as well.
    func systemShortcutConflict(for hotkey: Hotkey) -> Hotkey? {
        hotkey.systemShortcutConflict(in: systemShortcuts)
    }

    var needsAccessibility: Bool { !accessibilityTrusted }
    /// Without Accessibility the chord has to contain a regular key, so the
    /// recorder refuses modifier-only chords and settings says why.
    var hotkeyNeedsRegularKey: Bool { !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    /// Polls permission status every 2 s for the app's life. Neither API
    /// offers a change notification, so this is how the menu and the settings
    /// window notice a permission flipped in System Settings — and, since
    /// `refreshPermissions()` swaps the hotkey source, how the app moves
    /// between the event tap and Carbon in both directions. It used to stop
    /// once both permissions were granted; a later revoke has to be picked up
    /// too, and two cheap status reads every two seconds cost nothing.
    private func startPermissionMirroring() {
        refreshPermissions()
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshPermissions()
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
        case .copied: return "Copied — press ⌘V"
        case .idle:
            return readyLine
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
            case .ready: return readyLine
            }
        }
    }

    /// The chord to hold, named the way the monitor that matches it sees the
    /// keys: the tap tells Left from Right, Carbon's mask cannot.
    var effectiveHotkeyName: String {
        guard !accessibilityTrusted else { return settings.hotkey.displayName }
        return (fallbackHotkey ?? settings.hotkey).sideAgnosticDisplayName
    }

    /// What to say when nothing is happening. Without Accessibility the stored
    /// chord may be listening for nothing, in which case a stand-in is named
    /// instead; "hold Right Command" would be a lie.
    private var readyLine: String {
        if let fallback = fallbackHotkey {
            return "Ready — hold \(fallback.sideAgnosticDisplayName) (Accessibility is off)"
        }
        if !accessibilityTrusted, !settings.hotkey.canBeRegisteredWithoutAccessibility {
            // Every candidate is taken by a macOS shortcut on this Mac.
            return "Choose a key combination in Settings (Accessibility is off)"
        }
        return "Ready — hold \(effectiveHotkeyName)"
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
