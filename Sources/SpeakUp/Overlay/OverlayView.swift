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

/// What the pill looks like, with the live audio level projected out.
///
/// `DictationState.recording` carries a level that changes many times a second.
/// Driving the capsule's morph animation off the state itself would restart
/// that animation on every meter update, so the morph animates on this
/// level-free phase instead while the bars animate on their own.
private enum OverlayPhase: Equatable {
    case empty
    case recording
    case transcribing
    case done
    case error(String)

    init(_ state: DictationState) {
        switch state {
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .inserting: self = .done
        case .error(let message): self = .error(message)
        case .idle, .unavailable: self = .empty
        }
    }
}

/// Liquid Glass pill: a capsule that samples the desktop behind the
/// transparent panel and morphs between the recording, transcribing, done and
/// error states.
struct OverlayView: View {
    let model: OverlayModel

    @Namespace private var glassNamespace

    private var phase: OverlayPhase { OverlayPhase(model.state) }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .glassEffect(.regular, in: Capsule())
                .glassEffectID("pill", in: glassNamespace)
        }
        // Glass carries its own edge highlight; this is only enough shadow to
        // lift the pill off a light desktop.
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .animation(.smooth(duration: 0.25), value: phase)
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
                    .shadow(color: .red.opacity(0.6), radius: 4)
                LevelBars(level: level)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .inserting:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Keeps a long message inside the panel instead of letting
                    // the capsule grow past its edges.
                    .frame(maxWidth: 232)
            }
        case .idle, .unavailable:
            Color.clear.frame(width: 100)
        }
    }
}

/// Fourteen bars whose heights follow the input level. Bars near the middle are
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
                    .fill(.primary)
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
