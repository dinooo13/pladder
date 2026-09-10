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
                FootnoteText("Hold to record, release to insert. Click the key and press any key or combination, then let go. Left and right modifiers are different keys, so Right Command on its own works. Pressing anything else while holding it stops the recording, so shortcuts keep working.")
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
                            Text(unavailabilityReason(for: processor) ?? processor.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(isDisabled(processor))
                }
            } header: {
                Text("Processors")
            } footer: {
                FootnoteText("Each dictation runs through these in order before it is inserted.")
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
