import AppKit
import SwiftUI
import PladderCore

// A row of picture cards that is one radio group to VoiceOver and the keyboard: arrow keys
// move the choice while the row has focus.
struct OptionCardRow<Option: Hashable, Thumbnail: View>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let name: (Option) -> String
    @ViewBuilder let thumbnail: (Option) -> Thumbnail

    @FocusState private var focused: Bool

    init(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        name: @escaping (Option) -> String,
        @ViewBuilder thumbnail: @escaping (Option) -> Thumbnail
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.name = name
        self.thumbnail = thumbnail
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                OptionCard(
                    title: name(option),
                    isSelected: selection == option,
                    showsFocus: focused && selection == option,
                    action: { selection = option }
                ) {
                    thumbnail(option)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            switch direction {
            case .left where index > 0: selection = options[index - 1]
            case .right where index < options.count - 1: selection = options[index + 1]
            default: break
            }
        }
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

struct OptionCard<Thumbnail: View>: View {
    let title: String
    let isSelected: Bool
    var showsFocus = false
    let action: @MainActor () -> Void
    @ViewBuilder let thumbnail: Thumbnail

    // Computed, since a generic type cannot hold static stored values.
    private static var designSize: CGSize { CGSize(width: 132, height: 84) }
    private static var scale: CGFloat { 0.75 }
    private static var cardSize: CGSize {
        CGSize(width: (designSize.width * scale).rounded(), height: (designSize.height * scale).rounded())
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(width: Self.designSize.width, height: Self.designSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
                    .scaleEffect(Self.scale)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    // The ring sits in the padding, so selecting a card does not reflow the row.
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 3)
                            .padding(-3)
                            .opacity(showsFocus ? 1 : 0)
                    )
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// The real `OverlayPill` scaled down, so the cards can never drift from it.
struct OverlayStyleThumbnail: View {
    let style: OverlayStyle

    private static let previewLevel: Float = 0.55

    var body: some View {
        DesktopWash()
            // Overlay rather than ZStack: a scaled-down pill still lays out at full size, and in
            // a ZStack that would stretch the backdrop so the card only shows its middle.
            .overlay(alignment: style == .menuBar ? .top : .bottom) {
                content
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .compact:
            OverlayPill(state: .recording, level: Self.previewLevel, style: .compact, isPreview: true)
                .fixedSize()
                .scaleEffect(0.62)
                .padding(.bottom, 2)
        case .minimal:
            OverlayPill(state: .recording, level: Self.previewLevel, style: .minimal, isPreview: true)
                .fixedSize()
                .scaleEffect(0.8)
                .padding(.bottom, 10)
        case .menuBar:
            menuBar
        case .liveTranscript:
            OverlayPill(
                state: .recording,
                level: Self.previewLevel,
                style: .liveTranscript,
                isPreview: true,
                partial: String(localized: "as you speak"),
                hugsContent: true
            )
            // Proposed at the card's width the glass shrinks but the row does not, and the dot
            // ends up outside the capsule.
            .fixedSize()
            .scaleEffect(0.55)
            .padding(.bottom, 4)
        }
    }

    private var menuBar: some View {
        // Resized, not scaled: `scaleEffect` keeps the 22×16 layout and would push the strip
        // to the icon's height.
        Rectangle()
            .fill(.background.opacity(0.7))
            .frame(height: 14)
            .overlay(alignment: .trailing) {
                Image(nsImage: MenuBarIcon.image(for: .recording, level: Self.previewLevel))
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 10)
                    .foregroundStyle(.primary)
                    .padding(.trailing, 8)
            }
    }
}

// A neutral stand-in desktop: a coloured wallpaper would tint the glass and pull the eye.
struct DesktopWash: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(white: 0.30), Color(white: 0.16)]
                : [Color(white: 0.93), Color(white: 0.80)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
