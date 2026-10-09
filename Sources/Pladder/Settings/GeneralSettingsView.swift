import SwiftUI
import PladderCore

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            EngineSection(model: model)
            PushToTalkSection(model: model)
            AppearanceSection(model: model)
            OverlaySection(model: model)
            SoundsSection(model: model)
            PermissionsSection(permissions: model.permissions)
        }
        .formStyle(.grouped)
        // Re-read here rather than on the poll: the user may have just changed it in System
        // Settings, and this window is where it shows.
        .onAppear {
            model.settingsWindowOpened()
        }
    }
}

private struct EngineSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker("Engine", selection: $model.settings.engineID) {
                ForEach(model.registry.available) { entry in
                    Text(LocalizedStringKey(entry.displayName)).tag(entry.id)
                }
            }
        } header: {
            Text("Engine")
        } footer: {
            // The registry's own text, localized where it is built.
            FootnoteText(verbatim: model.registry.entry(for: model.settings.engineID)?.detail ?? "")
        }
    }
}

private struct PushToTalkSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Key") {
                HotkeyRecorderField(
                    hotkey: $model.settings.hotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    // The send key is off without Accessibility anyway.
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            }
            if let warning = HotkeyWarning.forKey(
                model.settings.hotkey, standIn: model.hotkeys.standInHotkey,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent("Toggle key") {
                HotkeyRecorderField(
                    hotkey: $model.settings.toggleHotkey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    requiresRegularKey: model.hotkeys.hotkeyNeedsRegularKey,
                    allowsEmpty: true,
                    systemShortcuts: model.hotkeys.systemShortcuts
                )
            }
            if let warning = HotkeyWarning.forToggle(
                model.settings.toggleHotkey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted,
                systemShortcuts: model.hotkeys.systemShortcuts) {
                WarningLabel(warning.text)
            }
            LabeledContent("Send key") {
                HotkeyRecorderField(
                    hotkey: $model.settings.submitKey,
                    setHotkeySuspended: model.setHotkeySuspended,
                    allowsEmpty: true
                )
            }
            if let warning = HotkeyWarning.forSendKey(
                model.settings.submitKey, hotkey: model.settings.hotkey,
                accessibilityTrusted: model.permissions.accessibilityTrusted) {
                WarningLabel(warning.text)
            }
        } header: {
            Text("Push to Talk")
        } footer: {
            // Separate literals, so each translation stays whole.
            VStack(alignment: .leading, spacing: 4) {
                FootnoteText("Hold to record, release to insert. Press the send key while recording and Return is pressed after the text. Click a field and press any key combination to assign it.")
                FootnoteText("Tap the toggle key to start recording and tap it again to insert. Set it to the same combination as the key and a short tap toggles while a hold still works as before. Escape discards a recording. Delete clears a field.")
            }
        }
    }
}

private struct AppearanceSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Appearance") {
                HStack(spacing: 8) {
                    ForEach(Appearance.allCases, id: \.self) { appearance in
                        OptionCard(
                            title: appearance.displayName,
                            isSelected: model.settings.appearance == appearance,
                            action: { model.settings.appearance = appearance }
                        ) {
                            AppearanceThumbnail(appearance: appearance, glass: model.settings.overlayGlass)
                        }
                    }
                }
            }
        }
    }
}

private struct OverlaySection: View {
    @Bindable var model: AppModel

    // Menu never flies a pill in, so the background and the speed have nothing to act on.
    private var hasPill: Bool { model.settings.overlayStyle != .menuBar }

    var body: some View {
        Section {
            LabeledContent("Style") {
                HStack(spacing: 8) {
                    ForEach(OverlayStyle.allCases, id: \.self) { style in
                        OptionCard(
                            title: style.displayName,
                            isSelected: model.settings.overlayStyle == style,
                            action: { model.settings.overlayStyle = style }
                        ) {
                            OverlayStyleThumbnail(style: style, glass: model.settings.overlayGlass)
                        }
                    }
                }
            }
            LabeledContent("Background") {
                HStack(spacing: 8) {
                    ForEach([true, false], id: \.self) { glass in
                        OptionCard(
                            title: glass ? String(localized: "Glass") : String(localized: "Flat"),
                            isSelected: model.settings.overlayGlass == glass,
                            isEnabled: hasPill,
                            action: { model.settings.overlayGlass = glass }
                        ) {
                            BackgroundThumbnail(glass: glass)
                        }
                    }
                }
            }
            LabeledContent("Animation") {
                HStack(spacing: 8) {
                    ForEach(OverlayAnimationSpeed.allCases, id: \.self) { speed in
                        OptionCard(
                            title: speed.displayName,
                            isSelected: model.settings.overlayAnimationSpeed == speed,
                            isEnabled: hasPill,
                            action: { model.settings.overlayAnimationSpeed = speed }
                        ) {
                            AnimationSpeedThumbnail(speed: speed)
                        }
                    }
                }
            }
        } header: {
            Text("Overlay")
        } footer: {
            FootnoteText("Shown while you dictate, flying up from the bottom edge as a circle and expanding into place. Menu relies on the wave in the menu bar alone; errors still appear.")
        }
    }
}

private struct SoundsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Sounds & Startup") {
            Toggle("Play start and stop sounds", isOn: $model.settings.playSounds)
            Toggle("Mute audio while dictating", isOn: $model.settings.muteOutputWhileDictating)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PermissionsSection: View {
    let permissions: PermissionMonitor

    var body: some View {
        Section("Permissions") {
            PermissionRow(
                title: "Accessibility",
                detail: String(localized: "Needed for a modifier-only key such as Right Command, for the send key and for pasting. Without it Option+Space still works and the text is copied for you to paste with ⌘V; a standard account needs an administrator to switch it on."),
                granted: permissions.accessibilityTrusted,
                action: permissions.grantAccessibility
            )
            PermissionRow(
                title: "Microphone",
                detail: microphoneDetail,
                granted: permissions.microphoneStatus == .authorized,
                action: permissions.grantMicrophone
            )
        }
    }

    private var microphoneDetail: String {
        switch permissions.microphoneStatus {
        case .authorized: String(localized: "Granted.")
        case .denied, .restricted: String(localized: "Denied. Enable it in System Settings.")
        default: String(localized: "Not requested yet.")
        }
    }
}

private extension Appearance {
    var displayName: String {
        switch self {
        case .system: String(localized: "Auto")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

private extension OverlayStyle {
    var displayName: String {
        switch self {
        case .menuBar: String(localized: "Menu")
        case .minimal: String(localized: "Minimal")
        case .compact: String(localized: "Compact")
        case .liveTranscript: String(localized: "Live")
        }
    }
}

private extension OverlayAnimationSpeed {
    var displayName: String {
        switch self {
        case .instant: String(localized: "Ludicrous")
        case .quick: String(localized: "Quick")
        case .expressive: String(localized: "Chill")
        }
    }
}
