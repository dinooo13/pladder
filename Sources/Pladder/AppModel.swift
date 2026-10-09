import AppKit
import Foundation
import Observation
import PladderCore
import os

import PladderSystem
import PladderAudio
import PladderEngines
import PladderRefine

// The composition root. The parts split off it: docs/ARCHITECTURE.md, "The app".
@MainActor
@Observable
final class AppModel {
    let registry: EngineRegistry
    let coordinator: DictationCoordinator
    let permissions: PermissionMonitor
    let hotkeys: HotkeyRouter
    let polish: PolishModelController
    let corrections: CorrectionInbox
    private(set) var launchAtLoginError: String?
    // Can change behind the app's back in System Settings: re-read when settings open.
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private let events = MainActorRelay<(DictationCoordinator.Event, ContinuousClock.Instant)>()
    @ObservationIgnored private var releaseInstant: ContinuousClock.Instant?
    private static let timingLog = Logger(subsystem: "de.dinooo13.pladder", category: "timing")
    // A stuck mute is silent and baffling otherwise, so both ends are logged `.public`.
    private nonisolated static let muteLog = Logger(subsystem: "de.dinooo13.pladder", category: "mute")
    private static let hotkeyLog = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")
    private static let settingsLog = Logger(subsystem: "de.dinooo13.pladder", category: "settings")

    // Each side effect runs only when its own keys changed: re-assigning `NSApp.appearance`
    // with a forced Light or Dark re-themes every window, and on every click of a
    // settings card it made the rows lag behind the click.
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
        // The catalog's detail is an English catalog key, worded here, where the catalog is.
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
        // One read: the store moves an undecodable file aside on load, so a second read
        // could see different settings.
        var initial = store.load()
        // A removed engine's ID would still work, but the picker should show what runs.
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
            // Stamped when emitted, not when the main actor gets to it, so the release-to-paste
            // measurement leaves out scheduling delay.
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
            // After the paste, outside the measured window. Only a paste that stayed in its
            // field can be corrected: a copy was never pasted, and a send emptied the field.
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
            // No paste, so no timing line, but the microphone went off and the user should hear it.
            releaseInstant = nil
            if settings.playSounds { SoundPlayer.playStop() }
        case .keyboardBounceObserved:
            // That wait comes before `recordingStopped`, so the timing line cannot show it.
            let window = coordinator.bounceWindow.timeInterval * 1000
            Self.hotkeyLog.notice("keyboard bounce observed: releases now settle for \(window, format: .fixed(precision: 0)) ms before stopping")
        }
    }

    // MARK: Menu

    var menuBarImage: NSImage {
        MenuBarIcon.image(for: coordinator.state, level: coordinator.inputLevel)
    }

    var statusLine: String {
        MenuStatus.line(
            state: coordinator.state,
            engineStatus: coordinator.engineStatus,
            isLatched: coordinator.isLatched,
            chords: menuChords)
    }

    // Without Accessibility the stored chord may listen for nothing, so the stand-in is
    // named: "hold Right Command" would be a lie.
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

    func setHotkeySuspended(_ suspended: Bool) {
        coordinator.isHotkeySuspended = suspended
    }

    func retryEngine() {
        coordinator.reloadEngine()
    }

    func copyLastTranscript() {
        guard let text = coordinator.lastTranscript?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
