import SwiftUI
import PladderCore

enum SettingsTab: Hashable {
    case general, text, dictionary
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .fittingContent()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            TextSettingsView(model: model)
                .fittingContent()
                .tabItem { Label("Text", systemImage: "textformat") }
                .tag(SettingsTab.text)

            DictionaryView(model: model)
                .fittingContent()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)
        }
        // No material or glass on the window: Apple's own settings windows are plain. The
        // fixed width keeps switching tabs from resizing the window sideways.
        .frame(width: 540)
    }
}

extension View {
    // A grouped Form is a scroll view and proposes no height of its own; fixed vertically
    // with scrolling off it takes its content's, so each tab is as tall as what it shows,
    // as in the system's own settings windows.
    func fittingContent() -> some View {
        scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
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
