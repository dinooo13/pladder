import SwiftUI
import PladderCore

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // First, until dictation can work, and for the rest of that session with a line
            // saying it is ready, so finishing setup has an end rather than a vanishing section.
            if model.showsGetStarted {
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
    // Only for trying the gesture once: never saved, gone with the section.
    @State private var practice = ""

    private var permissions: PermissionMonitor { model.permissions }

    var body: some View {
        Section {
            if permissions.needsMicrophone {
                PermissionRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    buttonTitle: permissions.microphoneStatus == .notDetermined
                        ? String(localized: "Allow…") : String(localized: "Open System Settings"),
                    isPrimary: true,
                    action: permissions.grantMicrophone
                )
            }
            if permissions.needsAccessibility {
                PermissionRow(
                    title: "Accessibility",
                    detail: String(localized: "Lets Pladder paste for you. Without it, the text is copied and you press ⌘V."),
                    buttonTitle: permissions.promptedForAccessibility
                        ? String(localized: "Open System Settings") : String(localized: "Allow…"),
                    isPrimary: !permissions.needsMicrophone,
                    action: permissions.grantAccessibility
                )
            }
            SpeechModelProgress(model: model)
            if !model.needsSetup {
                Label {
                    Text("Pladder is ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                // The first dictation, right where setup ends: the gesture is learnt by doing it.
                TextField("Try it", text: $practice, prompt: Text("Click here, hold \(model.holdShortcut) and say hello"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        } header: {
            Text("Get Started")
        } footer: {
            if model.needsSetup {
                Text("Then click into any text field, hold \(model.holdShortcut) and talk.")
            } else {
                Text("It works the same in every app with a text field.")
            }
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
                    let percent = Int((fraction * 100).rounded())
                    if let size = model.registry.entry(for: model.settings.engineID)?.downloadMegabytes {
                        Text("\(percent)% of \(size) MB")
                    } else {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
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
            Toggle("Open at Login", isOn: Binding(
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
        Section("Keyboard Shortcuts") {
            LabeledContent {
                HotkeyRecorderField(
                    title: "Talk key",
                    hotkey: $model.settings.hotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            } label: {
                Text("Talk key")
                Text("Hold to record, release to paste. Escape discards.")
            }
            if let warning = HotkeyWarning.forKey(
                model.settings.hotkey, standIn: model.hotkeys.standInHotkey,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent {
                HotkeyRecorderField(
                    title: "Hands-free key",
                    hotkey: $model.settings.toggleHotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    allowsEmpty: true,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            } label: {
                Text("Hands-free key")
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
                    title: "Send key",
                    hotkey: $model.settings.submitKey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    allowsEmpty: true
                )
            } label: {
                Text("Send key")
                Text("Press while talking to send the text with Return.")
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
                title: String(localized: "Recording Indicator"),
                selection: $model.settings.overlayStyle,
                // The site's order, from the most shown to the least.
                options: [.compact, .minimal, .liveTranscript, .menuBar],
                name: \.displayName
            ) { style in
                OverlayStyleThumbnail(style: style)
            }
        } header: {
            Text("Recording Indicator")
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
                Text("Model")
                // The registry's own text, localized where it is built.
                Text(verbatim: model.registry.entry(for: model.settings.engineID)?.detail ?? "")
            }
            if !model.showsGetStarted {
                SpeechModelProgress(model: model)
            }
        } header: {
            Text("Speech Model")
        }
    }
}

extension OverlayStyle {
    var displayName: String {
        switch self {
        case .menuBar: String(localized: "Menu bar only")
        case .minimal: String(localized: "Minimal")
        case .compact: String(localized: "Compact")
        case .liveTranscript: String(localized: "Live")
        }
    }

}
