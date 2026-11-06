import AppKit
import SwiftUI
import PladderCore

// The live row measures its words with these, so the measurement never drifts from
// what is drawn.
enum PillMetrics {
    static let fontSize: CGFloat = 13
    static let font = Font.system(size: fontSize, weight: .medium)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    static let rowSpacing: CGFloat = 10
    static let dotSize: CGFloat = 8
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3
    static let barsHeight: CGFloat = 24

    static func barsWidth(count: Int) -> CGFloat {
        CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * barSpacing
    }
}

extension Color {
    // #FF6A47, the icon's caret in `scripts/make-icon.swift` and the site's accent.
    static let brandCoral = Color(.sRGB, red: 1, green: 0x6A / 255, blue: 0x47 / 255)
}

struct RecordingDot: View {
    var size: CGFloat = PillMetrics.dotSize

    var body: some View {
        Circle()
            .fill(Color.brandCoral)
            .frame(width: size, height: size)
    }
}

// Glass only: Reduce Transparency already turns it opaque, so there is no switch of its own.
struct PillBackground: ViewModifier {
    var namespace: Namespace.ID?
    @Environment(\.colorSchemeContrast) private var contrast

    // One shape for row and disc: a capsule in a square is a circle, so the morph is only
    // the size. `AnyShape` cannot interpolate between two shape types; a `Circle` would snap.
    private var shape: Capsule { Capsule() }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if let namespace {
                content
                    .glassEffect(.regular, in: shape)
                    .glassEffectID("pill", in: namespace)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        }
        // Increase Contrast: glass on a dark window otherwise has no edge at all.
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}

struct LevelBars: View {
    let level: Float
    let count: Int
    let maxHeight: CGFloat
    let opacity: Double

    private static let minScale: CGFloat = 0.1

    @State private var meter: WaveformMeter
    @State private var heights: [CGFloat]

    // `seeded` pre-rolls the meter, so a replica that never sees a level shows a wave.
    init(level: Float, count: Int, maxHeight: CGFloat, opacity: Double, seeded: Bool = false) {
        self.level = level
        self.count = count
        self.maxHeight = maxHeight
        self.opacity = opacity

        var meter = WaveformMeter(count: count)
        var initial = Array(repeating: Self.minScale, count: count)
        if seeded {
            var shaped: [Float] = []
            for _ in 0..<8 { shaped = meter.update(level: level) }
            initial = shaped.map { max(Self.minScale, CGFloat($0)) }
        }
        _meter = State(initialValue: meter)
        _heights = State(initialValue: initial)
    }

    var body: some View {
        HStack(alignment: .center, spacing: PillMetrics.barSpacing) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(opacity))
                    .frame(width: PillMetrics.barWidth, height: max(PillMetrics.barWidth, heights[index] * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .onChange(of: level) { _, new in
            let next = meter.update(level: new)
            withAnimation(.easeOut(duration: 0.1)) {
                heights = next.map { max(Self.minScale, CGFloat($0)) }
            }
        }
    }
}
