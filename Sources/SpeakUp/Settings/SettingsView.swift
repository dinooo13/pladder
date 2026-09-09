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
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Launch at login", isOn: launchAtLogin)
                    if let error = model.launchAtLoginError {
                        Text(error)
                            .font(.caption)
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
                ForEach(model.processors, id: \.id) { processor in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(processor.displayName, isOn: binding(for: processor.id))
                            .disabled(isDisabled(processor))
                        Text(unavailabilityReason(for: processor) ?? processor.detail)
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

    private func isDisabled(_ processor: any TextProcessor) -> Bool {
        unavailabilityReason(for: processor) != nil
    }

    private func unavailabilityReason(for processor: any TextProcessor) -> String? {
        guard processor.id == FoundationModelProcessor.processorID else { return nil }
        return FoundationModelProcessor.availability
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
