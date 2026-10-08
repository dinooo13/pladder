import AppKit
import SwiftUI
import PladderCore

/// The pill's type and meter geometry, in one place: every row draws with
/// these, and the live row measures its words and works out its width from
/// them, so the measurement can never drift from what is drawn.
enum PillMetrics {
    static let fontSize: CGFloat = 13
    static let font = Font.system(size: fontSize, weight: .medium, design: .rounded)
    /// The same face as an `NSFont`, for measuring.
    @MainActor static let nsFont: NSFont = {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: fontSize)
        else { return base }
        return rounded
    }()
    /// Between the dot, the meter and the words or label of a row.
    static let rowSpacing: CGFloat = 10
    static let dotSize: CGFloat = 8
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3

    static func barsWidth(count: Int) -> CGFloat {
        CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * barSpacing
    }
}

/// The red "live" dot, shared by Compact, Minimal and the settings replicas.
struct RecordingDot: View {
    var size: CGFloat = PillMetrics.dotSize

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.6), radius: 4)
    }
}

/// What sits behind the pill: Liquid Glass, or a flat window-background
/// capsule with a hairline border for people who want the desktop to stay
/// still. The shadow is added by whoever hosts the pill.
struct PillBackground: ViewModifier {
    let glass: Bool
    /// Only the live overlay morphs between states, so the glass identity is
    /// optional; the settings replicas pass nothing.
    var namespace: Namespace.ID?

    /// One shape for the rows and the Minimal disc: a capsule in a square is
    /// a circle, so the disc↔row morph is purely the animated size. A
    /// separate `Circle` would snap — `Circle()` in a row-sized frame draws a
    /// disc in the middle of the row at once, and `AnyShape` cannot
    /// interpolate between two shape types, so the collapse would be over
    /// before it started.
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

/// Bars whose heights follow the input level. The shaping (amplitude curve,
/// bell envelope, wobble, rise/fall blend) lives in the shared
/// `WaveformMeter`, so this wave matches the menu bar glyph exactly.
struct LevelBars: View {
    let level: Float
    let count: Int
    let maxHeight: CGFloat
    let opacity: Double

    private static let minScale: CGFloat = 0.1

    @State private var meter: WaveformMeter
    @State private var heights: [CGFloat]

    /// `seeded` pre-rolls the meter so a static replica (the settings cards,
    /// which never see a level change) shows a wave rather than a row of
    /// stubs.
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
