import AppKit
import PladderCore

// A template image, so it takes the menu bar's tint; the bars mirror
// `scripts/make-icon.swift`.
enum MenuBarIcon {
    // Few enough to cache every variant, so the label follows the level without redrawing.
    enum Variant: Hashable {
        case idle
        // Quantised, so the image cache stays bounded.
        case recording(step: Int)
        case busy
        case off

        static let levelSteps = 6

        init(state: DictationState, level: Float) {
            switch state {
            // The clipboard hint is neither failure nor work: the overlay carries the message.
            case .idle, .copied: self = .idle
            case .recording:
                let amp = CGFloat(WaveformMeter.amplitude(for: level))
                self = .recording(step: Int((amp * CGFloat(Self.levelSteps - 1)).rounded()))
            case .transcribing, .polishing, .inserting: self = .busy
            case .unavailable, .error: self = .off
            }
        }
    }

    private static let envelope: [CGFloat] = [0.20, 0.36, 0.58, 0.82, 1.0, 0.82, 0.58, 0.36, 0.20]

    // Bar and gap widths on half points keep the capsules crisp on Retina menu bars.
    private static let barWidth: CGFloat = 1.5
    private static let gap: CGFloat = 1.0
    private static let maxBarHeight: CGFloat = 14
    private static let canvas = NSSize(width: 22, height: 16)

    @MainActor private static var cache: [Variant: NSImage] = [:]

    @MainActor
    static func image(for state: DictationState, level: Float = 0) -> NSImage {
        image(for: Variant(state: state, level: level))
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
