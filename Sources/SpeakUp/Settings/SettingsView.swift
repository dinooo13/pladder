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
                Picker("Key", selection: $model.settings.hotkey) {
                    ForEach(Hotkey.presets, id: \.hotkey) { preset in
                        Text(preset.name).tag(preset.hotkey)
                    }
                }
            } header: {
                Text("Push to Talk")
            } footer: {
                FootnoteText("Hold to record, release to insert. Holding it together with another key does nothing, so shortcuts keep working.")
            }

            Section("Output") {
                Toggle("Append a space after each dictation", isOn: $model.settings.appendTrailingSpace)
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
                Toggle(isOn: binding(for: model.dictionaryProcessor.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.dictionaryProcessor.displayName)
                        Text(model.dictionaryProcessor.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                FootnoteText("Runs first, so the optional cleanup step below sees your fixed-up terms.")
            }

            Section {
                Toggle("Clean up transcripts", isOn: $model.settings.cleanupEnabled)

                Picker("Using", selection: $model.settings.cleanupProviderID) {
                    ForEach(model.cleanupRegistry.available) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
                .disabled(!model.settings.cleanupEnabled)
            } header: {
                Text("Cleanup")
            } footer: {
                Text(cleanupFooter)
                    .font(.callout)
                    .foregroundStyle(model.cleanupAvailability != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: binding(for: model.whitespaceProcessor.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.whitespaceProcessor.displayName)
                        Text(model.whitespaceProcessor.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                FootnoteText("Runs last, right before the text is inserted.")
            }
        }
        .formStyle(.grouped)
    }

    /// Text shown under the "Using" picker: the selected provider's
    /// unavailability reason when it has one, otherwise its detail line.
    private var cleanupFooter: String {
        if let reason = model.cleanupAvailability {
            return reason
        }
        let selected = model.cleanupRegistry.entry(for: model.settings.cleanupProviderID)
        return selected?.detail ?? ""
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
                    .buttonStyle(.glass)
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
