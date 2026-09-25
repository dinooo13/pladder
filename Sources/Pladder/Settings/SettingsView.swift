import AVFoundation
import SwiftUI
import PladderCore
import PladderRefine

import PladderSystem

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

private struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
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

            Section {
                LabeledContent("Key") {
                    HotkeyRecorderField(
                        hotkey: $model.settings.hotkey,
                        onRecordingChanged: { model.coordinator.isHotkeySuspended = $0 },
                        // The send key is off without Accessibility anyway, so
                        // only the push-to-talk key is constrained.
                        requiresRegularKey: model.hotkeyNeedsRegularKey,
                        systemShortcuts: model.systemShortcuts
                    )
                }
                if let warning = hotkeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Toggle key") {
                    HotkeyRecorderField(
                        hotkey: $model.settings.toggleHotkey,
                        onRecordingChanged: { model.coordinator.isHotkeySuspended = $0 },
                        requiresRegularKey: model.hotkeyNeedsRegularKey,
                        allowsEmpty: true,
                        systemShortcuts: model.systemShortcuts
                    )
                }
                if let warning = toggleKeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Send key") {
                    HotkeyRecorderField(
                        hotkey: $model.settings.submitKey,
                        onRecordingChanged: { model.coordinator.isHotkeySuspended = $0 },
                        // Empty has always meant off; now the field can say so.
                        allowsEmpty: true
                    )
                }
                 if let warning = submitKeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Push to Talk")
            } footer: {
                // Separate literals, so each translation stays whole and
                // another key can add its own line.
                VStack(alignment: .leading, spacing: 4) {
                    FootnoteText("Hold to record, release to insert. Press the send key while recording and Return is pressed after the text. Click a field and press any key combination to assign it.")
                    FootnoteText("Tap the toggle key to start recording and tap it again to insert. Set it to the same combination as the key and a short tap toggles while a hold still works as before. Escape discards a recording. Delete clears a field.")
                }
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
                            title: String(localized: "Glass"),
                            isSelected: model.settings.overlayGlass,
                            isEnabled: model.settings.overlayStyle != .menuBar,
                            action: { model.settings.overlayGlass = true }
                        ) {
                            BackgroundThumbnail(glass: true)
                        }
                        OptionCard(
                            title: String(localized: "Flat"),
                            isSelected: !model.settings.overlayGlass,
                            isEnabled: model.settings.overlayStyle != .menuBar,
                            action: { model.settings.overlayGlass = false }
                        ) {
                            BackgroundThumbnail(glass: false)
                        }
                    }
                }
                LabeledContent("Animation") {
                    HStack(spacing: 8) {
                        ForEach(OverlayAnimationSpeed.allCases, id: \.self) { speed in
                            OptionCard(
                                title: speed.displayName,
                                isSelected: model.settings.overlayAnimationSpeed == speed,
                                // Menu never flies a pill in, so like the
                                // background the speed has nothing to act on.
                                isEnabled: model.settings.overlayStyle != .menuBar,
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

            Section("Sounds & Startup") {
                Toggle("Play start and stop sounds", isOn: $model.settings.playSounds)
                Toggle("Mute audio while dictating", isOn: $model.settings.muteOutputWhileDictating)
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
                    detail: String(localized: "Needed for a modifier-only key such as Right Command, for the send key and for pasting. Without it Option+Space still works and the text is copied for you to paste with ⌘V; a standard account needs an administrator to switch it on."),
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
        // The shortcuts macOS owns are re-read here rather than on the
        // permission poll: this window is where they are shown, and the user
        // may have just changed them in System Settings.
        .onAppear {
            model.refreshPermissions()
            model.refreshSystemShortcuts()
        }
    }

    /// In order: the stored chord cannot be detected, so the default stands in
    /// for it — and if macOS owns that too, say so instead, since it is the
    /// chord actually being listened for; macOS owns the stored chord, so it
    /// may never arrive; and the standing warning that a chord without a
    /// modifier is swallowed system wide, so a plain letter or Space would
    /// become untypeable while Pladder runs.
    private var hotkeyWarning: String? {
        let hotkey = model.settings.hotkey
        if let standIn = model.standInHotkey {
            if let owner = model.systemShortcutConflict(for: standIn) {
                return conflictWarning(owner: owner, chord: standIn)
            }
            return String(localized: "Without Accessibility, \(hotkey.displayName) cannot be detected, so \(standIn.sideAgnosticDisplayName) stands in for it until Accessibility is granted. Record a combination with a regular key to choose your own.")
        }
        if let owner = model.systemShortcutConflict(for: hotkey) {
            return conflictWarning(owner: owner, chord: hotkey)
        }
        guard hotkey.modifierKeyCodes.isEmpty, !hotkey.keyCodes.isEmpty else { return nil }
        return String(localized: "Without a modifier, \(hotkey.displayName) can no longer be typed in other apps while Pladder is running.")
    }

    /// Nothing for an empty toggle key, or one equal to the key: that one is
    /// hybrid, and whatever stands in for the key stands in for it too.
    /// Otherwise a chord Carbon cannot register listens for nothing without
    /// Accessibility, and has no stand-in of its own, since the only candidate
    /// is the push-to-talk stand-in; and macOS may own the chord.
    private var toggleKeyWarning: String? {
        let toggle = model.settings.toggleHotkey
        guard !toggle.isEmpty, toggle.canonical != model.settings.hotkey.canonical else { return nil }
        if !model.accessibilityTrusted && !toggle.canBeRegisteredWithoutAccessibility {
            return String(localized: "Without Accessibility, \(toggle.displayName) cannot be detected, so the toggle key is off until Accessibility is granted.")
        }
        if let owner = model.systemShortcutConflict(for: toggle) {
            return conflictWarning(owner: owner, chord: toggle)
        }
        return nil
    }

    /// An enabled macOS shortcut is dispatched by the window server before
    /// either monitor sees the keys, so the chord may simply never arrive.
    private func conflictWarning(owner: Hotkey, chord: Hotkey) -> String {
        String(localized: "\(owner.sideAgnosticDisplayName) is a macOS keyboard shortcut, so \(chord.displayName) may never reach Pladder. Record another combination.")
    }

    /// The send key presses Return through the same synthetic event as the
    /// paste, so it is off entirely without Accessibility. Otherwise: a send
    /// key the chord already contains can never be pressed on its own.
    private var submitKeyWarning: String? {
        let submitKey = model.settings.submitKey
        guard !submitKey.keyCodes.isEmpty else { return nil }
        if !model.accessibilityTrusted {
            return String(localized: "The send key needs Accessibility.")
        }
        guard submitKey.keyCodes.isSubset(of: model.settings.hotkey.keyCodes) else { return nil }
        return String(localized: "\(submitKey.displayName) is part of the push-to-talk key, so it can never be pressed separately.")
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var micDetail: String {
        switch model.microphoneStatus {
        case .authorized: String(localized: "Granted.")
        case .denied, .restricted: String(localized: "Denied. Enable it in System Settings.")
        default: String(localized: "Not requested yet.")
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
                            // Core cannot import the catalog, so its
                            // processors are looked up by their English text.
                            Text(LocalizedStringKey(processor.displayName))
                            Text(LocalizedStringKey(processor.detail))
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

            Section {
                Toggle("Polish dictations", isOn: $model.settings.polishDictations)
                Picker("Model", selection: $model.settings.polishModel) {
                    ForEach(PolishModel.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                polishModelStatus
            } header: {
                Text("Experimental")
            } footer: {
                FootnoteText("Before the text is pasted, the model cleans it up on this Mac: self-corrections, spoken punctuation, lists. Apple Intelligence adds one to two seconds to every dictation, S1-mini by Superwhisper about half a second. S1-mini is trained on English, also handles German and Spanish, and is downloaded once from Hugging Face when you pick it. Anything a model cannot fix is pasted as dictated.")
            }
        }
        .formStyle(.grouped)
    }

    /// What stands between the chosen model and a polished dictation:
    /// Apple Intelligence switched off, or an S1-mini file still to come.
    @ViewBuilder
    private var polishModelStatus: some View {
        if let status = model.polishModelStatus {
            switch status {
            case .ready:
                EmptyView()
            case .missing:
                FootnoteText("Downloads when polish is on.")
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(model.settings.polishModel.displayName)…")
                        .font(.callout)
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            case .verifying:
                ProgressView {
                    Text("Checking the download…").font(.callout)
                }
            case .failed(let failure):
                HStack(alignment: .firstTextBaseline) {
                    Label(failure.text, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") { model.retryPolishModelDownload() }
                }
            }
        } else if let warning = model.polishAvailability.polishKeyText {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    let title: LocalizedStringKey
    /// Already in the user's language: the callers build it with
    /// `String(localized:)` because it depends on the permission's state.
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
    private let text: Text

    /// A literal, which the String Catalog translates.
    init(_ key: LocalizedStringKey) { text = Text(key) }
    /// Text that is already in the user's language, or has no translation to
    /// give it: an engine's detail line, an error from the system.
    init(verbatim text: String) { self.text = Text(text) }

    var body: some View {
        text
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
