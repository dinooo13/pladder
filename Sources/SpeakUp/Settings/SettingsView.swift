import AVFoundation
import SwiftUI
import SpeakUpCore

import SpeakUpSystem

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }

            DictionaryView(model: model)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            ProcessingSettingsView(model: model)
                .tabItem { Label("Processing", systemImage: "wand.and.sparkles") }
        }
        // Deliberately no material or glass on the window itself: Apple's own
        // settings windows are plain, and Liquid Glass belongs on the controls
        // and the overlay pill. The fixed width keeps switching tabs from
        // resizing the window sideways; height follows the tallest content.
        .frame(width: 540)
        .frame(minHeight: 540)
    }
}

private extension Appearance {
    var displayName: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

private extension OverlayStyle {
    var displayName: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .minimal: "Minimal"
        case .compact: "Compact"
        case .liveTranscript: "Live"
        }
    }

    /// The live transcript pill is shown as a disabled card until #8 lands,
    /// so the row already reads the way it finally will.
    var isSelectable: Bool { self != .liveTranscript }
}

private struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $model.settings.engineID) {
                    ForEach(model.registry.available) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
            } header: {
                Text("Engine")
            } footer: {
                FootnoteText(model.registry.entry(for: model.settings.engineID)?.detail ?? "")
            }

            Section {
                LabeledContent("Key") {
                    HotkeyRecorderField(
                        hotkey: $model.settings.hotkey,
                        onRecordingChanged: { model.coordinator.isHotkeySuspended = $0 }
                    )
                }
                if let warning = hotkeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Push to Talk")
            } footer: {
                FootnoteText("Hold to record, release to insert. Click the field and press any key combination to assign it.")
            }

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

            Section {
                LabeledContent("Style") {
                    HStack(spacing: 8) {
                        ForEach(OverlayStyle.allCases, id: \.self) { style in
                            OptionCard(
                                title: style.displayName,
                                isSelected: model.settings.overlayStyle == style,
                                isEnabled: style.isSelectable,
                                action: { model.settings.overlayStyle = style }
                            ) {
                                OverlayStyleThumbnail(style: style, glass: model.settings.overlayGlass)
                            }
                        }
                    }
                }
                LabeledContent("Background") {
                    HStack(spacing: 8) {
                        OptionCard(
                            title: "Glass",
                            isSelected: model.settings.overlayGlass,
                            isEnabled: model.settings.overlayStyle != .menuBar,
                            action: { model.settings.overlayGlass = true }
                        ) {
                            BackgroundThumbnail(glass: true)
                        }
                        OptionCard(
                            title: "Flat",
                            isSelected: !model.settings.overlayGlass,
                            isEnabled: model.settings.overlayStyle != .menuBar,
                            action: { model.settings.overlayGlass = false }
                        ) {
                            BackgroundThumbnail(glass: false)
                        }
                    }
                }
            } header: {
                Text("Overlay")
            } footer: {
                FootnoteText("Shown while you dictate. Menu Bar only relies on the wave in the menu bar; errors still appear.")
            }

            Section("Sounds & Startup") {
                Toggle("Play start and stop sounds", isOn: $model.settings.playSounds)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Launch at login", isOn: launchAtLogin)
                    if let error = model.launchAtLoginError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed for the global hotkey and pasting.",
                    granted: model.accessibilityTrusted,
                    action: model.grantAccessibility
                )
                PermissionRow(
                    title: "Microphone",
                    detail: micDetail,
                    granted: model.microphoneStatus == .authorized,
                    action: model.grantMicrophone
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
    }

    /// A chord without a modifier is swallowed system wide, so a plain letter
    /// or Space would become untypeable while SpeakUp runs.
    private var hotkeyWarning: String? {
        let hotkey = model.settings.hotkey
        guard hotkey.modifierKeyCodes.isEmpty, !hotkey.keyCodes.isEmpty else { return nil }
        return "Without a modifier, \(hotkey.displayName) can no longer be typed in other apps while SpeakUp is running."
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var micDetail: String {
        switch model.microphoneStatus {
        case .authorized: "Granted."
        case .denied, .restricted: "Denied. Enable it in System Settings."
        default: "Not requested yet."
        }
    }
}

private struct ProcessingSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.processors, id: \.id) { processor in
                    Toggle(isOn: binding(for: processor.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(processor.displayName)
                            Text(processor.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Processors")
            } footer: {
                FootnoteText("Each dictation runs through these in order before it is inserted.")
            }

            Section {
                Toggle("Append a space after each dictation", isOn: $model.settings.appendTrailingSpace)
            } header: {
                Text("Output")
            } footer: {
                FootnoteText("Separates consecutive dictations so pasted runs stay readable.")
            }
        }
        .formStyle(.grouped)
    }

    /// Settings stores the *disabled* IDs, so absence means on.
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledProcessors.contains(id) },
            set: { model.settings.setProcessor(id, enabled: $0) }
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: @MainActor () -> Void

    var body: some View {
        LabeledContent {
            if !granted {
                Button("Open Settings…") { action() }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
            }
        }
    }
}

/// Section footer styling, the native macOS pattern: secondary colour, callout
/// size, wrapping instead of truncating.
struct FootnoteText: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
