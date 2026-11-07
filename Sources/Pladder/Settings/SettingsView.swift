import AppKit
import SwiftUI
import PladderCore

enum SettingsTab: Hashable {
    case general, text, dictionary
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State var tab: SettingsTab = .general
    // Only the screenshots set it, to show each tab of the real window in turn.
    @MainActor static var requestedTab: SettingsTab? {
        didSet { if let requestedTab { TabRequest.shared.tab = requestedTab } }
    }
    @State private var request = TabRequest.shared

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
        .onChange(of: request.tab) { _, new in if let new { tab = new } }
    }
}

@MainActor
@Observable
final class TabRequest {
    static let shared = TabRequest()
    var tab: SettingsTab?
}

extension View {
    // Each tab as tall as what it shows, as in the system's own settings windows, but never
    // taller than the screen: past that the form scrolls.
    func fittingContent() -> some View {
        modifier(FittingContent())
    }
}

private struct FittingContent: ViewModifier {
    // A grouped Form is a scroll view and proposes no height of its own, so the height is
    // its content's, read back from the scroll view.
    @State private var contentHeight: CGFloat?

    // The window's title bar and tab toolbar, and some desktop above and below.
    private static let chromeAndMargin: CGFloat = 140

    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return screen - Self.chromeAndMargin
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // The content alone: the top inset is the toolbar the window slides the form under
                // while it resizes, and adding it fed every resize back into the next one.
                geometry.contentSize.height.rounded()
            } action: { _, height in
                contentHeight = height
            }
            .frame(height: min(contentHeight ?? maxHeight, maxHeight))
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

// Work under way, as System Settings shows it: the sentence, and a small spinner at the
// trailing edge. The regular size is a 32 pt wheel that outweighs the form.
struct BusyRow: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        LabeledContent {
            ProgressView()
                .controlSize(.small)
        } label: {
            Text(text)
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
            Group {
                if isPrimary {
                    Button(buttonTitle) { action() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(buttonTitle) { action() }
                }
            }
            // The button keeps its own title, the action; the row says what it is for.
            .accessibilityHint(Text(detail))
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
