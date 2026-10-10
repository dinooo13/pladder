import SwiftUI
import PladderCore

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

/// An orange line under a control that says why it may not do what the user
/// expects. Already in the user's language.
struct WarningLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionRow: View {
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
