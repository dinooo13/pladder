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
                    action: { selection = option }
                ) {
                    thumbnail(option)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .focusable()
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
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(isSelected ? 1 : 0)
                    )
                Text(title)
                    .font(.callout)
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
                partial: String(localized: "Hi"),
                hugsContent: true
            )
            // Proposed at the card's width the glass shrinks but the row does not, and the dot
            // ends up outside the capsule.
            .fixedSize()
            .scaleEffect(0.8)
            .padding(.bottom, 4)
        }
    }

    // A strip of menu bar with its neighbours, so the card reads as the menu bar and not as
    // an empty desktop.
    private var menuBar: some View {
        HStack(spacing: 7) {
            Spacer()
            // Resized, not scaled: `scaleEffect` keeps the 22×16 layout and would push the
            // strip to the icon's height.
            Image(nsImage: MenuBarIcon.image(for: .recording, level: Self.previewLevel))
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(height: 11)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "switch.2")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(.background.opacity(0.75))
    }
}

// A neutral stand-in desktop: a coloured wallpaper would tint the glass and pull the eye.
struct DesktopWash: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(white: 0.34), Color(white: 0.14)]
                : [Color(white: 0.90), Color(white: 0.70)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
