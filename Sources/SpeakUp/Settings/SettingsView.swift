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

            VStack {
                Text("Dictionary editor coming in milestone 3")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 480, height: 360)
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
                if let detail = model.registry.entry(for: model.settings.engineID)?.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Push-to-talk key", selection: hotkeyIndex) {
                    ForEach(Array(Hotkey.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.name).tag(index)
                    }
                }
            }

            Section {
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

    /// `Hotkey` is only `Equatable`, so the picker selects by preset index.
    private var hotkeyIndex: Binding<Int> {
        Binding(
            get: { Hotkey.presets.firstIndex { $0.hotkey == model.settings.hotkey } ?? 0 },
            set: { model.settings.hotkey = Hotkey.presets[$0].hotkey }
        )
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
