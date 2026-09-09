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
            .frame(width: 196, height: 52)
            .background(.ultraThinMaterial, in: Capsule())
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private static let count = 14
    private static let minScale: CGFloat = 0.1
    private static let maxHeight: CGFloat = 32

    @State private var heights: [CGFloat] = Array(repeating: minScale, count: LevelBars.count)
    @State private var tick = 0

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.count, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.8))
                    .frame(width: 3, height: max(3, heights[index] * Self.maxHeight))
            }
        }
        .frame(height: Self.maxHeight)
        .onChange(of: level) { _, new in
            tick &+= 1
            withAnimation(.easeOut(duration: 0.1)) {
                heights = Self.blend(previous: heights, level: new, tick: tick)
            }
        }
    }

    private static func blend(previous: [CGFloat], level: Float, tick: Int) -> [CGFloat] {
        // Boost the mid range so ordinary speech swings the bars most of the
        // way, and let loud peaks saturate.
        let amplitude = min(1, pow(CGFloat(min(max(level, 0), 1)), 0.7) * 1.3)
        let centre = CGFloat(count - 1) / 2
        let phase = CGFloat(tick) * 0.9
        return (0..<count).map { index in
            // Soft envelope: full height in the middle, half at the ends.
            let distance = abs(CGFloat(index) - centre) / centre
            let envelope = 1 - distance * distance * 0.5
            // Each bar follows its own slow wave so the shape moves while the
            // level is steady, and the wave shifts on every update.
            let wobble = 0.65 + 0.35 * (0.5 + 0.5 * sin(CGFloat(index) * 1.7 + phase))
            let target = minScale + amplitude * envelope * wobble * (1 - minScale)
            // Rise fast, fall slower, so peaks read clearly.
            let weight: CGFloat = target > previous[index] ? 0.7 : 0.45
            return previous[index] * (1 - weight) + target * weight
        }
    }
}
