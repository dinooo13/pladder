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
        // Fixed size for every tab, so switching tabs never resizes the window.
        .frame(width: 520, height: 420)
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
                Text(model.registry.entry(for: model.settings.engineID)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Push to talk") {
                Picker("Key", selection: $model.settings.hotkey) {
                    ForEach(Hotkey.presets, id: \.hotkey) { preset in
                        Text(preset.name).tag(preset.hotkey)
                    }
                }
                Text("Hold to record, release to insert. Holding it together with another key does nothing, so shortcuts keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Output") {
                Toggle("Append a space after each dictation", isOn: $model.settings.appendTrailingSpace)
                Toggle("Play start and stop sounds", isOn: $model.settings.playSounds)
                Toggle("Launch at login", isOn: launchAtLogin)
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
            get: { model.settings.launchAtLogin },
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

    private struct ProcessorInfo: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    /// Listed in pipeline order. IDs must match the processors the app builds.
    private static let processors: [ProcessorInfo] = [
        ProcessorInfo(
            id: DictionaryReplacer.processorID,
            title: "Dictionary",
            detail: "Applies your replacement rules. Edit them in the Dictionary tab."
        ),
        ProcessorInfo(
            id: WhitespaceNormalizer.processorID,
            title: "Tidy whitespace",
            detail: "Trims the transcript and collapses runs of spaces."
        ),
        ProcessorInfo(
            id: "foundation-model",
            title: "Apple Intelligence cleanup",
            detail: "Fixes punctuation and capitalisation with the on-device model. Adds about a second. Requires Apple Intelligence."
        ),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.processors) { processor in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(processor.title, isOn: binding(for: processor.id))
                        Text(processor.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Processors")
            } footer: {
                Text("Each dictation runs through these in order before it is inserted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings…") { action() }
            }
        }
    }
}
