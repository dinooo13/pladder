import AppKit
import Foundation
import Observation
import PladderCore
import os

import PladderSystem
import PladderAudio
import PladderEngines
import PladderRefine

/// Composition root. Builds the engine registry, the settings store, the
/// coordinator and the parts around it, owns the settings, and turns the
/// coordinator's events into sounds, log lines and learning.
///
/// What each part does lives with it: `HotkeyRouter` picks the hotkey
/// source, `PermissionMonitor` polls the grants, `PolishModelController`
/// owns the polish model, `CorrectionInbox` the learned corrections, and the
/// menu's wording is in `StatusText.swift`.
@MainActor
@Observable
final class AppModel {
    let registry: EngineRegistry
    let coordinator: DictationCoordinator
    let permissions: PermissionMonitor
    let hotkeys: HotkeyRouter
    let polish: PolishModelController
    let corrections: CorrectionInbox

    /// Set when `setLaunchAtLogin` fails, so settings can show the reason
    /// under the toggle.
    private(set) var launchAtLoginError: String?
    /// The login item's state, which can be changed behind the app's back in
    /// System Settings: re-read when the settings window opens.
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private let events = MainActorRelay<(DictationCoordinator.Event, ContinuousClock.Instant)>()

    /// When the hotkey was released, for the release-to-paste measurement.
    @ObservationIgnored private var releaseInstant: ContinuousClock.Instant?

    /// Release-to-paste time per dictation, the number the user feels. Read
    /// it with: log show --last 1h --predicate 'subsystem == "de.dinooo13.pladder"'
    private static let timingLog = Logger(subsystem: "de.dinooo13.pladder", category: "timing")
    /// Every mute and unmute of the output device. A mute that gets stuck —
    /// the app quitting mid-recording, a device vanishing — is silent and
    /// baffling otherwise, so both ends of it are logged `.public`.
    private nonisolated static let muteLog = Logger(subsystem: "de.dinooo13.pladder", category: "mute")
    /// Hotkey behaviour worth knowing about after the fact, such as a
    /// keyboard that bounces.
    private static let hotkeyLog = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")
    private static let settingsLog = Logger(subsystem: "de.dinooo13.pladder", category: "settings")

    /// The settings, persisted on every real change. Assignments that change
    /// nothing are ignored, and each side effect runs only when its own keys
    /// changed. Re-assigning `NSApp.appearance` is not free: with a forced
    /// Light or Dark it makes AppKit re-theme every window, so doing it on
    /// every click of a settings card made the card rows lag behind the
    /// click. The coordinator sees only `DictationSettings`, and only when
    /// that part changed.
    var settings: Settings {
        get { storedSettings }
        set {
            let old = storedSettings
            guard newValue != old else { return }
            storedSettings = newValue
            settingsChanged(from: old)
        }
    }
    private var storedSettings: Settings

    init(location: SettingsLocation) {
        // Engines, in the order the settings picker shows them. The first
        // entry is the default for new installs. The catalog's detail is the
        // English catalog key; it is worded here, where the catalog is.
        var registry = EngineRegistry()
        for var entry in StandardEngines.entries {
            entry.detail = String(localized: String.LocalizationValue(entry.detail))
            registry.register(entry)
        }
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

        location.migrateLegacySettingsIfNeeded()
        store = SettingsStore(url: location.settingsURL, defaults: Settings(engineID: StandardEngines.defaultEntry.id))
        // One read: the store moves an undecodable file aside on load, so a
        // second read could see different settings than the first.
        var initial = store.load()
        // An engine that was removed in an update leaves a stale ID behind.
        // `EngineRegistry.make` already falls back to the first entry, so the
        // app works either way; rewriting the ID keeps the settings picker
        // showing what is actually running.
        if registry.entry(for: initial.engineID) == nil, let fallback = registry.available.first {
            initial.engineID = fallback.id
        }
        storedSettings = initial

        let permissions = PermissionMonitor()
        self.permissions = permissions
        let hotkeys = HotkeyRouter(accessibilityTrusted: permissions.accessibilityTrusted, hotkey: initial.hotkey)
        self.hotkeys = hotkeys
        let polish = PolishModelController()
        self.polish = polish

        let events = self.events
        let coordinator = DictationCoordinator(
            settings: DictationSettings(initial),
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            outputMuter: OutputMuteController(
                control: CoreAudioOutputMute(),
                log: { Self.muteLog.info("\($0, privacy: .public)") }),
            refiner: polish.refiner,
            hotkeyMonitor: hotkeys.initialMonitor,
            makePipeline: { StandardProcessors.pipeline(for: $0) },
            // Stamped when the coordinator emits it, not when the main actor
            // gets to it, so the release-to-paste measurement does not
            // include scheduling delay.
            onEvent: { event in events.send((event, .now)) }
        )
        self.coordinator = coordinator
        hotkeys.attach(coordinator)
        corrections = CorrectionInbox(dismissedURL: location.dismissedCorrectionsURL)
        overlay = OverlayController(coordinator: coordinator)

        events.handler = { [weak self] in self?.handle($0.0, at: $0.1) }
        corrections.dictionary = { [weak self] in self?.settings.dictionary ?? [] }
        corrections.addRules = { [weak self] rules in self?.settings.dictionary.merge(rules) }
        corrections.isQuiet = { [weak self] in self?.coordinator.state.isBusy != true }
        permissions.onRefresh = { [weak self] in self?.permissionsRefreshed() }
    }

    // MARK: Lifecycle

    func start() {
        applyAppearance(settings.appearance)
        overlay.applyStyle(settings.overlayStyle, glass: settings.overlayGlass)
        overlay.applySpeed(settings.overlayAnimationSpeed)
        permissions.start()
        overlay.start()
        coordinator.start()
        polish.apply(model: settings.polishModel, polishing: settings.polishDictations)
    }

    /// The app is quitting: everything the coordinator borrowed is given
    /// back first. The app delegate waits for this, with a deadline.
    func shutdown() async {
        permissions.stop()
        overlay.stop()
        await coordinator.shutdown()
    }

    private func permissionsRefreshed() {
        hotkeys.update(
            accessibilityTrusted: permissions.accessibilityTrusted,
            secureInputEnabled: permissions.secureInputEnabled)
        polish.refreshAvailability()
    }

    /// Re-reads what can change behind the app's back and is about to be
    /// shown: the grants, the shortcuts macOS owns, the login item.
    func settingsWindowOpened() {
        permissions.refresh()
        hotkeys.refreshSystemShortcuts()
        let enabled = LaunchAtLogin.isEnabled
        if enabled != launchAtLoginEnabled { launchAtLoginEnabled = enabled }
    }

    // MARK: Settings

    private func settingsChanged(from old: Settings) {
        let dictation = DictationSettings(settings)
        if dictation != coordinator.settings { coordinator.settings = dictation }
        if settings.appearance != old.appearance {
            applyAppearance(settings.appearance)
        }
        if settings.overlayStyle != old.overlayStyle || settings.overlayGlass != old.overlayGlass {
            overlay.applyStyle(settings.overlayStyle, glass: settings.overlayGlass)
        }
        if settings.overlayAnimationSpeed != old.overlayAnimationSpeed {
            overlay.applySpeed(settings.overlayAnimationSpeed)
        }
        if settings.hotkey != old.hotkey {
            hotkeys.hotkeyChanged(to: settings.hotkey)
        }
        if settings.polishModel != old.polishModel || settings.polishDictations != old.polishDictations {
            polish.apply(model: settings.polishModel, polishing: settings.polishDictations)
        }
        do {
            try store.save(settings)
        } catch {
            Self.settingsLog.error("could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applying the appearance to `NSApp` covers every window and menu at
    /// once, so no view has to care; the overlay's panel is told on its own.
    private func applyAppearance(_ appearance: Appearance) {
        NSApp.appearance = appearance.nsAppearance
        overlay.applyAppearance(appearance)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    // MARK: Events

    private func handle(_ event: DictationCoordinator.Event, at instant: ContinuousClock.Instant) {
        switch event {
        case .recordingStarted:
            if settings.playSounds { SoundPlayer.playStart() }
        case .recordingStopped:
            releaseInstant = instant
            if settings.playSounds { SoundPlayer.playStop() }
        case .inserted(let insertion):
            // Strictly after the paste and off the measured window, which
            // ended when the coordinator emitted this event. Only a paste
            // that stayed in its field can be corrected: a copy was never
            // pasted, and a send emptied the field.
            defer {
                if insertion.result == .pasted, !insertion.submitted {
                    corrections.pasted(insertion.transcript.text)
                }
            }
            guard let released = releaseInstant else { return }
            releaseInstant = nil
            let line = insertion.timingLine(total: instant - released, polishModel: settings.polishModel.rawValue)
            Self.timingLog.log("\(line, privacy: .public)")
        case .failed:
            releaseInstant = nil
        case .recordingDiscarded:
            // Escape: no paste follows, so no timing line either, but the
            // microphone did go off and the user should hear it.
            releaseInstant = nil
            if settings.playSounds { SoundPlayer.playStop() }
        case .keyboardBounceObserved:
            // That wait comes before `recordingStopped`, so the timing line
            // cannot show it; this line is what explains a felt delay.
            let window = coordinator.bounceWindow.timeInterval * 1000
            Self.hotkeyLog.notice("keyboard bounce observed: releases now settle for \(window, format: .fixed(precision: 0)) ms before stopping")
        }
    }

    // MARK: Menu

    /// The app icon's waveform glyph, varied by state (see `MenuBarIcon`).
    var menuBarImage: NSImage {
        MenuBarIcon.image(for: coordinator.state)
    }

    /// One line describing what the app is doing right now.
    var statusLine: String {
        MenuStatus.line(
            state: coordinator.state,
            engineStatus: coordinator.engineStatus,
            isLatched: coordinator.isLatched,
            chords: menuChords)
    }

    /// The chords the menu names. Without Accessibility the stored chord may
    /// be listening for nothing, so the stand-in is named instead; "hold
    /// Right Command" would be a lie. Any chord ends a latched recording;
    /// the line names the one that latched it: the toggle key when it is a
    /// chord of its own, otherwise the key, or what stands in for it.
    private var menuChords: MenuStatus.Chords {
        let standIn = hotkeys.standInHotkey?.sideAgnosticDisplayName
        let hold = standIn ?? hotkeys.displayName(of: settings.hotkey)
        let toggle = settings.toggleHotkey
        let stop = !toggle.isEmpty && toggle.canonical != settings.hotkey.canonical
            ? hotkeys.displayName(of: toggle) : hold
        return MenuStatus.Chords(
            hold: hold, stop: stop,
            accessibilityOff: standIn != nil,
            secureKeyboardEntry: hotkeys.usesCarbonForSecureInput)
    }

    var canRetryEngine: Bool {
        if case .failed = coordinator.engineStatus { return true }
        return false
    }

    var lastTranscriptSummary: String? {
        coordinator.lastTranscript.flatMap { MenuStatus.summary(of: $0.text) }
    }
}

extension Appearance {
    /// `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
