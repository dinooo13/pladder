import AppKit
import SwiftUI
import PladderCore

// The live row measures its words with these, so the measurement never drifts from
// what is drawn.
enum PillMetrics {
    static let fontSize: CGFloat = 13
    static let font = Font.system(size: fontSize, weight: .medium, design: .rounded)
    @MainActor static let nsFont: NSFont = {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: fontSize)
        else { return base }
        return rounded
    }()
    static let rowSpacing: CGFloat = 10
    static let dotSize: CGFloat = 8
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3

    static func barsWidth(count: Int) -> CGFloat {
        CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * barSpacing
    }
}

struct RecordingDot: View {
    var size: CGFloat = PillMetrics.dotSize

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.6), radius: 4)
    }
}

struct PillBackground: ViewModifier {
    let glass: Bool
    var namespace: Namespace.ID?

    // One shape for row and disc: a capsule in a square is a circle, so the morph is only
    // the size. `AnyShape` cannot interpolate between two shape types; a `Circle` would snap.
    private var shape: Capsule { Capsule() }

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            if let namespace {
                content
                    .glassEffect(.regular, in: shape)
                    .glassEffectID("pill", in: namespace)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
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
