import AppKit
import SwiftUI
import PladderCore

struct OptionCard<Thumbnail: View>: View {
    let title: String
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: @MainActor () -> Void
    @ViewBuilder let thumbnail: Thumbnail

    // Computed, since a generic type cannot hold static stored values.
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
                    // A hairline edge, mostly for dark mode, where a dark desktop sinks into the window.
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.2), lineWidth: 1.5))
                    .scaleEffect(Self.scale)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    // The ring sits in the padding, so selecting a card does not reflow the row.
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

struct DesktopThumbnail<Content: View>: View {
    // The Appearance cards force theirs, so light and dark can be shown side by side.
    var scheme: ColorScheme?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var environmentScheme

    private var resolved: ColorScheme { scheme ?? environmentScheme }

    var body: some View {
        DesktopWash(scheme: resolved)
        // Overlay rather than ZStack: a scaled-down pill still lays out at full size, and in a
        // ZStack that would stretch the gradient so the card only shows its middle.
        .overlay {
            content
                .environment(\.colorScheme, resolved)
        }
    }
}

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
            OverlayPill(state: .recording, level: 0.55, style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(height: 2)
        }
    }
}

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

// The real `OverlayPill` scaled down, so the cards can never drift from it.
struct OverlayStyleThumbnail: View {
    let style: OverlayStyle
    let glass: Bool

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
            OverlayPill(state: .recording, level: Self.previewLevel, style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        case .minimal:
            // The disc is 44 pt; at 0.75 it still reads as a disc, not a dot.
            OverlayPill(state: .recording, level: Self.previewLevel, style: .minimal, glass: glass, isPreview: true)
                .scaleEffect(0.75)
        case .menuBar:
            menuBar
        case .liveTranscript:
            // Scaled to about 72 pt of the card's 88: small, but the words read as words.
            OverlayPill(
                state: .recording,
                level: Self.previewLevel,
                style: .liveTranscript,
                glass: glass,
                isPreview: true,
                partial: String(localized: "see it as you speak"),
                hugsContent: true
            )
            // Proposed at the card's width the glass shrinks but the row does not, and the dot
            // ends up outside the capsule.
            .fixedSize()
            .scaleEffect(0.42)
        }
    }

    private var menuBar: some View {
        // Resized, not scaled: `scaleEffect` keeps the 22×16 layout and would push the strip
        // to the icon's height.
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(height: 9)
            .overlay(alignment: .trailing) {
                Image(nsImage: MenuBarIcon.image(for: .recording, level: Self.previewLevel))
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

struct BackgroundThumbnail: View {
    let glass: Bool

    var body: some View {
        DesktopThumbnail {
            OverlayPill(state: .recording, level: 0.55, style: .compact, glass: glass, isPreview: true)
                .scaleEffect(0.5)
        }
    }
}

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

struct DesktopWash: View {
    let scheme: ColorScheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.30, green: 0.36, blue: 0.70), Color(red: 0.10, green: 0.12, blue: 0.32)]
                : [Color(red: 0.62, green: 0.78, blue: 0.97), Color(red: 0.24, green: 0.46, blue: 0.88)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
