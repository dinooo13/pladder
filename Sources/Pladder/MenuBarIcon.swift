import AppKit
import PladderCore

/// The app icon's waveform glyph, drawn as a menu bar template image so it
/// takes the menu bar's tint in light and dark mode. The bar layout mirrors
/// `scripts/make-icon.swift`; state is conveyed by the bars themselves rather
/// than by swapping SF Symbols.
enum MenuBarIcon {
    /// What the glyph looks like for a given dictation state. Small enough to
    /// cache every variant, so the label can update on each level change
    /// while recording without redrawing.
    enum Variant: Hashable {
        case idle
        /// Bars follow the input level, quantised to `levelSteps` so the
        /// image cache stays bounded.
        case recording(step: Int)
        /// Transcribing, polishing or inserting: dimmed to read as "busy".
        case busy
        /// Engine unavailable or an error: slashed like `mic.slash`.
        case off

        static let levelSteps = 6

        init(state: DictationState) {
            switch state {
            // The clipboard hint is not a failure and not work in progress;
            // the glyph reads as ready while the overlay carries the message.
            case .idle, .copied: self = .idle
            case .recording(let level):
                // Quantise the same shared amplitude curve the overlay's
                // meter uses, so glyph and overlay wave agree on what the
                // input level means.
                let amp = CGFloat(WaveformMeter.amplitude(for: level))
                self = .recording(step: Int((amp * CGFloat(Self.levelSteps - 1)).rounded()))
            case .transcribing, .polishing, .inserting: self = .busy
            case .unavailable, .error: self = .off
            }
        }
    }

    /// Bell-shaped envelope from the app icon.
    private static let envelope: [CGFloat] = [0.20, 0.36, 0.58, 0.82, 1.0, 0.82, 0.58, 0.36, 0.20]

    // Geometry in points. Bar and gap widths land on half points so the
    // capsules stay crisp on Retina menu bars.
    private static let barWidth: CGFloat = 1.5
    private static let gap: CGFloat = 1.0
    private static let maxBarHeight: CGFloat = 14
    private static let canvas = NSSize(width: 22, height: 16)

    @MainActor private static var cache: [Variant: NSImage] = [:]

    @MainActor
    static func image(for state: DictationState) -> NSImage {
        image(for: Variant(state: state))
    }

    @MainActor
    static func image(for variant: Variant) -> NSImage {
        if let cached = cache[variant] { return cached }
        let image = render(variant)
        cache[variant] = image
        return image
    }

    private static func heights(for variant: Variant) -> [CGFloat] {
        switch variant {
        case .recording(let step):
            // Quiet input flattens the glyph to a line; louder input grows it
            // back towards the full envelope, matching the overlay's meter.
            let amount = CGFloat(step) / CGFloat(Variant.levelSteps - 1)
            let floor = envelope.min()!
            return envelope.map { floor + ($0 - floor) * amount }
        case .idle, .busy, .off:
            return envelope
        }
    }

    private static func render(_ variant: Variant) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            let heights = heights(for: variant)
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = (rect.width - totalWidth) / 2
            let alpha: CGFloat = variant == .busy ? 0.45 : 1

            let bars = NSBezierPath()
            for h in heights {
                let barHeight = max(barWidth, maxBarHeight * h)
                let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
                bars.append(NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2))
                x += barWidth + gap
            }
            NSColor.black.withAlphaComponent(alpha).setFill()
            bars.fill()

            if variant == .off {
                drawSlash(in: rect)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A diagonal stroke with a cleared halo, the same idiom SF Symbols use
    /// for their `.slash` variants.
    private static func drawSlash(in rect: NSRect) {
        let inset: CGFloat = 3
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        slash.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        slash.lineCapStyle = .round

        NSGraphicsContext.current?.compositingOperation = .clear
        slash.lineWidth = 4
        slash.stroke()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setStroke()
        slash.lineWidth = 1.5
        slash.stroke()
    }
}
