import SwiftUI
import PladderCore

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // First, and only until dictation can work: what is missing, and the download.
            if model.needsSetup {
                GetStartedSection(model: model)
            }
            StartupSection(model: model)
            ShortcutsSection(model: model)
            OverlaySection(model: model)
            SpeechModelSection(model: model)
        }
        .formStyle(.grouped)
        // Re-read here rather than on the poll: the user may have just changed it in System
        // Settings, and this window is where it shows.
        .onAppear {
            model.settingsWindowOpened()
        }
    }
}

private struct GetStartedSection: View {
    @Bindable var model: AppModel

    private var permissions: PermissionMonitor { model.permissions }

    var body: some View {
        Section {
            if permissions.needsMicrophone {
                PermissionRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    buttonTitle: permissions.microphoneStatus == .notDetermined
                        ? String(localized: "Allow…") : String(localized: "Open System Settings…"),
                    isPrimary: true,
                    action: permissions.grantMicrophone
                )
            }
            if permissions.needsAccessibility {
                PermissionRow(
                    title: "Accessibility",
                    detail: String(localized: "Lets Pladder paste for you. Without it, the text is copied and you press ⌘V."),
                    buttonTitle: String(localized: "Allow…"),
                    isPrimary: !permissions.needsMicrophone,
                    action: permissions.grantAccessibility
                )
            }
            SpeechModelProgress(model: model)
        } header: {
            Text("Get Started")
        } footer: {
            Text("Then click into any text field, hold \(model.holdShortcut) and talk.")
        }
    }

    private var microphoneDetail: String {
        switch permissions.microphoneStatus {
        case .denied, .restricted: String(localized: "Turned off for Pladder. Turn it on in System Settings to dictate.")
        default: String(localized: "Needed to hear you. Nothing you say leaves this Mac.")
        }
    }
}

// Shown in Get Started while it lasts, and in the speech model's own section after.
private struct SpeechModelProgress: View {
    let model: AppModel

    var body: some View {
        switch model.coordinator.engineStatus {
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading the speech model…")
            } currentValueLabel: {
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            }
        case .loading:
            ProgressView {
                Text("Loading the speech model…")
            }
        case .failed(let failure):
            LabeledContent {
                Button(model.retryEngineTitle) { model.retryEngine() }
            } label: {
                WarningLabel(failure.text)
            }
        case .ready, .unloaded:
            EmptyView()
        }
    }
}

private struct StartupSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let error = model.launchAtLoginError {
                WarningLabel(error)
            }
            Toggle("Play start and stop sounds", isOn: $model.settings.playSounds)
            Toggle(isOn: $model.settings.muteOutputWhileDictating) {
                Text("Mute other audio while recording")
                Text("So music or a call does not end up in the dictation.")
            }
        }
    }
}

private struct ShortcutsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Shortcuts") {
            LabeledContent {
                HotkeyRecorderField(
                    hotkey: $model.settings.hotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            } label: {
                Text("Push to talk")
                Text("Hold to record, release to paste. Escape discards.")
            }
            if let warning = HotkeyWarning.forKey(
                model.settings.hotkey, standIn: model.hotkeys.standInHotkey,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent {
                HotkeyRecorderField(
                    hotkey: $model.settings.toggleHotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    allowsEmpty: true,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            } label: {
                Text("Hands-free")
                Text("Tap to start, tap again to paste.")
            }
            if let warning = HotkeyWarning.forToggle(
                model.settings.toggleHotkey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent {
                HotkeyRecorderField(
                    hotkey: $model.settings.submitKey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    allowsEmpty: true
                )
            } label: {
                Text("Send")
                Text("Press while holding push to talk, and Return follows the text.")
            }
            if let warning = HotkeyWarning.forSendKey(
                model.settings.submitKey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted) {
                WarningLabel(warning.text)
            }
        }
    }
}

private struct OverlaySection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            OptionCardRow(
                title: String(localized: "Overlay"),
                selection: $model.settings.overlayStyle,
                options: OverlayStyle.allCases,
                name: \.displayName
            ) { style in
                OverlayStyleThumbnail(style: style)
            }
        } header: {
            Text("Overlay")
        } footer: {
            Text(verbatim: model.settings.overlayStyle.summary)
        }
    }
}

private struct SpeechModelSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker(selection: $model.settings.engineID) {
                ForEach(model.registry.available) { entry in
                    Text(LocalizedStringKey(entry.displayName)).tag(entry.id)
                }
            } label: {
                Text("Speech model")
                // The registry's own text, localized where it is built.
                Text(verbatim: model.registry.entry(for: model.settings.engineID)?.detail ?? "")
            }
            if !model.needsSetup {
                SpeechModelProgress(model: model)
            }
        } footer: {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text(verbatim: String(localized: "Pladder \(version)"))
            }
        }
    }
}

extension OverlayStyle {
    var displayName: String {
        switch self {
        case .menuBar: String(localized: "Menu Bar")
        case .minimal: String(localized: "Minimal")
        case .compact: String(localized: "Compact")
        case .liveTranscript: String(localized: "Live")
        }
    }

    var summary: String {
        switch self {
        case .compact: String(localized: "A small pill with a level meter, above the Dock.")
        case .minimal: String(localized: "A single dot that turns into a level meter.")
        case .liveTranscript: String(localized: "Shows the words as you speak them.")
        case .menuBar: String(localized: "Nothing on screen: the menu bar icon follows your voice. Errors still appear.")
        }
    }
}
