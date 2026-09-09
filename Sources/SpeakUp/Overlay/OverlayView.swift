import SwiftUI
import SpeakUpCore

/// The state the overlay renders. Kept separate from the coordinator so the
/// panel can be driven independently (and shown while fading out after the
/// coordinator has already returned to `.idle`).
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    init() {}
}

/// Wispr-style pill: a translucent capsule with a level meter, a spinner, or a
/// short status glyph.
struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(4)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording(let level):
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                LevelBars(level: level)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium))
            }
        case .inserting:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 13, weight: .medium))
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .idle, .unavailable:
            Color.clear
        }
    }
}

/// Twelve bars whose heights follow the input level. Bars near the middle are
/// taller, and each new level is blended into the previous heights so the meter
/// breathes instead of flickering.
private struct LevelBars: View {
    let level: Float

    private static let count = 12
    private static let minScale: CGFloat = 0.12

    @State private var heights: [CGFloat] = Array(repeating: minScale, count: LevelBars.count)

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.count, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.75))
                    .frame(width: 3, height: max(3, heights[index] * 26))
            }
        }
        .frame(height: 26)
        .onChange(of: level) { _, new in
            withAnimation(.easeOut(duration: 0.08)) {
                heights = Self.blend(previous: heights, level: new)
            }
        }
    }

    private static func blend(previous: [CGFloat], level: Float) -> [CGFloat] {
        let amplitude = CGFloat(min(max(level, 0), 1))
        let centre = CGFloat(count - 1) / 2
        return (0..<count).map { index in
            // Triangular envelope: 1.0 in the middle, 0.35 at the ends.
            let distance = abs(CGFloat(index) - centre) / centre
            let envelope = 1 - distance * 0.65
            // Fixed per-bar jitter keeps the shape organic without randomness
            // that would fight the animation.
            let jitter = 0.85 + 0.15 * CGFloat((index * 7 % 5)) / 4
            let target = minScale + amplitude * envelope * jitter * (1 - minScale)
            return previous[index] * 0.55 + target * 0.45
        }
    }
}
