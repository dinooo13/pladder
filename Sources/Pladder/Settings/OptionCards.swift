import AppKit
import SwiftUI
import PladderCore

/// A System-Settings-style picker cell: a picture of the choice with its name
/// under it and an accent ring when it is the current one. Used instead of a
/// segmented control where the choice is visual and a word alone does not say
/// what it looks like.
struct OptionCard<Thumbnail: View>: View {
    let title: String
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: @MainActor () -> Void
    @ViewBuilder let thumbnail: Thumbnail

    /// Thumbnails are laid out at this size and then scaled, so the mini
    /// windows and pills keep their proportions whatever the card size.
    /// (Computed, since a generic type cannot hold static stored values.)
    private static var designSize: CGSize { CGSize(width: 88, height: 56) }
    private static var scale: CGFloat { 2 / 3 }
    private static var cardSize: CGSize {
        CGSize(width: (designSize.width * scale).rounded(), height: (designSize.height * scale).rounded())
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                thumbnail
                    .frame(width: Self.designSize.width, height: Self.designSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // A hairline edge, mostly for dark mode, where a dark
                    // desktop otherwise sinks into the window behind it.
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.2), lineWidth: 1.5))
                    .scaleEffect(Self.scale)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    // The ring sits in the padding, so selecting a card does
                    // not move the picture or reflow the row.
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                    )
                Text(title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A stand-in desktop for a card: the same diagonal blue wash the stock
/// wallpapers use, light or dark, with whatever the card is illustrating
/// centred on top.
struct DesktopThumbnail<Content: View>: View {
    /// `nil` follows the settings window's own scheme; the Appearance cards
    /// force theirs so both can be shown side by side.
    var scheme: ColorScheme?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var environmentScheme

    private var resolved: ColorScheme { scheme ?? environmentScheme }

    var body: some View {
        LinearGradient(
            colors: resolved == .dark
                ? [Color(red: 0.30, green: 0.36, blue: 0.70), Color(red: 0.10, green: 0.12, blue: 0.32)]
                : [Color(red: 0.62, green: 0.78, blue: 0.97), Color(red: 0.24, green: 0.46, blue: 0.88)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        // Overlay rather than ZStack: a scaled-down pill still lays out at
        // its full size, and in a ZStack that would stretch the gradient so
        // the card only shows its middle. The card clips whatever hangs out.
        .overlay {
            content
                .environment(\.colorScheme, resolved)
        }
    }
}

/// Light, Dark and Auto, shown on the Compact pill (the default overlay) so
/// the card previews the thing the setting most visibly changes. Auto splits
/// the card along the diagonal, the way System Settings does.
struct AppearanceThumbnail: View {
    let appearance: Appearance
    let glass: Bool

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .light:
            desktop(.light)
        case .dark:
            desktop(.dark)
        case .system:
            ZStack {
                desktop(.light).mask { DiagonalHalf(leading: true) }
                desktop(.dark).mask { DiagonalHalf(leading: false) }
            }
        }
    }

    private func desktop(_ scheme: ColorScheme) -> some View {
        DesktopThumbnail(scheme: scheme) {
            OverlayPill(state: .recording(level: 0.55), style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        }
        .overlay(alignment: .top) {
            // The menu bar, just enough of it to read as "a Mac".
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(height: 2)
        }
    }
}

/// Half the card, split by the diagonal that runs from the top-right corner to
/// the bottom-left one.
private struct DiagonalHalf: Shape {
    let leading: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if leading {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// One overlay style, shown as it actually looks: the cards render the real
/// `OverlayPill` scaled down rather than a hand-drawn imitation, so they can
/// never drift from the pill itself.
struct OverlayStyleThumbnail: View {
    let style: OverlayStyle
    let glass: Bool

    @Environment(\.colorScheme) private var scheme

    private static let previewLevel: Float = 0.55

    var body: some View {
        DesktopThumbnail {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .compact:
            OverlayPill(state: .recording(level: Self.previewLevel), style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        case .minimal:
            // The disc is 44 pt; at 0.75 it reads as a disc without turning
            // into a dot.
            OverlayPill(state: .recording(level: Self.previewLevel), style: .minimal, glass: glass, isPreview: true)
                .scaleEffect(0.75)
        case .menuBar:
            // Nothing on the desktop at all: the wave in the menu bar is the
            // whole of this style.
            menuBar
        case .liveTranscript:
            // The live row hugs a two-line sample in a preview. The card's
            // design box is 88 pt wide, so the pill, 171 pt at full size, is
            // scaled to about 72 pt: the words are small but read as words,
            // which is what tells this style from Compact.
            OverlayPill(
                state: .recording(level: Self.previewLevel),
                style: .liveTranscript,
                glass: glass,
                isPreview: true,
                partial: String(localized: "see it as you speak"),
                hugsContent: true
            )
            // The card is narrower than the pill; proposed at the card's
            // width the glass shrinks but the row does not, and the dot ends
            // up outside the capsule. The pill takes its own size instead.
            .fixedSize()
            .scaleEffect(0.42)
        }
    }

    private var menuBar: some View {
        // The same strip the Appearance cards draw, tall enough to hold the
        // wave glyph. The image is resized, not scaled: `scaleEffect` keeps
        // the 22×16 layout and would push the strip to the icon's height.
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(height: 9)
            .overlay(alignment: .trailing) {
                Image(nsImage: MenuBarIcon.image(for: .recording(level: Self.previewLevel)))
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 7)
                    .foregroundStyle(.white)
                    .padding(.trailing, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Glass or flat, shown on the Compact pill since that is where the difference
/// is easiest to see.
struct BackgroundThumbnail: View {
    let glass: Bool

    var body: some View {
        DesktopThumbnail {
            OverlayPill(state: .recording(level: 0.55), style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        }
    }
}

/// A speed for the fly-in/fly-out. An animation cannot be captured in a
/// still picture, so each card says it with a speed instead: lightning for
/// almost instant, a hare for quick, a tortoise for the long expressive one.
struct AnimationSpeedThumbnail: View {
    let speed: OverlayAnimationSpeed

    var body: some View {
        DesktopThumbnail {
            Image(systemName: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .foregroundStyle(.white)
        }
    }

    private var icon: String {
        switch speed {
        case .instant: "bolt.fill"
        case .quick: "hare.fill"
        case .expressive: "tortoise.fill"
        }
    }
}
