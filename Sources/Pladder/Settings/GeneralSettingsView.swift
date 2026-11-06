import SwiftUI
import PladderCore

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // First, and only while something is missing: it is what stops dictation working.
            if model.permissions.needsAnyPermission {
                PermissionsSection(permissions: model.permissions)
            }
            SpeechModelSection(model: model)
            ShortcutsSection(model: model)
            OverlaySection(model: model)
            StartupSection(model: model)
        }
        .formStyle(.grouped)
        // Re-read here rather than on the poll: the user may have just changed it in System
        // Settings, and this window is where it shows.
        .onAppear {
            model.settingsWindowOpened()
        }
    }
}

private struct SpeechModelSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker("Speech model", selection: $model.settings.engineID) {
                ForEach(model.registry.available) { entry in
                    Text(LocalizedStringKey(entry.displayName)).tag(entry.id)
                }
            }
            switch model.coordinator.engineStatus {
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading the speech model…").font(.callout)
                } currentValueLabel: {
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                }
            case .loading:
                ProgressView {
                    Text("Loading the speech model…").font(.callout)
                }
            case .failed(let failure):
                HStack(alignment: .firstTextBaseline) {
                    WarningLabel(failure.text)
                    Spacer()
                    Button("Try Again") { model.retryEngine() }
                }
            case .ready, .unloaded:
                EmptyView()
            }
        } footer: {
            // The registry's own text, localized where it is built.
            FootnoteText(verbatim: model.registry.entry(for: model.settings.engineID)?.detail ?? "")
        }
    }
}

private struct ShortcutsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Push to talk") {
                HotkeyRecorderField(
                    hotkey: $model.settings.hotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            }
            .help("Hold to record, release to paste.")
            if let warning = HotkeyWarning.forKey(
                model.settings.hotkey, standIn: model.hotkeys.standInHotkey,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent("Hands-free") {
                HotkeyRecorderField(
                    hotkey: $model.settings.toggleHotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    allowsEmpty: true,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            }
            .help("Press once to start recording and again to paste. Set it to the push-to-talk key and a short tap starts hands-free while a hold works as before.")
            if let warning = HotkeyWarning.forToggle(
                model.settings.toggleHotkey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent("Paste and send") {
                HotkeyRecorderField(
                    hotkey: $model.settings.submitKey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    allowsEmpty: true
                )
            }
            .help("Press it while recording and Return follows the text, to send a message or run a command.")
            if let warning = HotkeyWarning.forSendKey(
                model.settings.submitKey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted) {
                WarningLabel(warning.text)
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            FootnoteText("Hold to record, release to paste. Escape discards a recording.")
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
            FootnoteText(verbatim: model.settings.overlayStyle.summary)
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
            Toggle("Mute other audio while recording", isOn: $model.settings.muteOutputWhileDictating)
        } footer: {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                FootnoteText(verbatim: String(localized: "Pladder \(version)"))
            }
        }
    }
}

private struct PermissionsSection: View {
    let permissions: PermissionMonitor

    var body: some View {
        Section {
            if permissions.needsMicrophone {
                PermissionRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    buttonTitle: permissions.microphoneStatus == .notDetermined
                        ? String(localized: "Allow…") : String(localized: "Open System Settings…"),
                    action: permissions.grantMicrophone
                )
            }
            if permissions.needsAccessibility {
                PermissionRow(
                    title: "Accessibility",
                    detail: String(localized: "Lets Pladder paste for you. Without it, the text is copied and you press ⌘V."),
                    buttonTitle: String(localized: "Open System Settings…"),
                    action: permissions.grantAccessibility
                )
            }
        } header: {
            Text("Permissions")
        }
    }

    private var microphoneDetail: String {
        switch permissions.microphoneStatus {
        case .denied, .restricted: String(localized: "Turned off for Pladder. Turn it on in System Settings to dictate.")
        default: String(localized: "Needed to hear you. Nothing you say leaves this Mac.")
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
