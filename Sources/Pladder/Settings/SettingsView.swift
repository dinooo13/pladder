import SwiftUI
import PladderCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .frame(height: model.needsSetup ? 800 : 640)
                .tabItem { Label("General", systemImage: "gearshape") }

            DictionaryView(model: model)
                .frame(height: model.settings.dictionary.isEmpty ? 460 : 560)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            TextSettingsView(model: model)
                .frame(height: model.settings.polishDictations ? 580 : 500)
                .tabItem { Label("Text", systemImage: "textformat") }
        }
        // No material or glass on the window: Apple's own settings windows are plain. The
        // fixed width keeps switching tabs from resizing the window sideways; each tab is as
        // tall as its content, as in the system's own settings windows.
        .frame(width: 540)
    }
}

// The sentence stays in the label colour; only the symbol carries the warning, since
// orange body text on the grouped form fails contrast.
struct WarningLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityLabel("Warning")
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: String
    let buttonTitle: String
    var isPrimary = false
    let action: @MainActor () -> Void

    var body: some View {
        LabeledContent {
            if isPrimary {
                Button(buttonTitle) { action() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(buttonTitle) { action() }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
