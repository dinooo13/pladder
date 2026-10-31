import AppKit
import PladderCore

// A template image, so it takes the menu bar's tint. The four bars and the
// caret are `scripts/make-icon.swift`'s mark, scaled to a 15 pt caret and
// rounded to whole and half points.
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

    private static let barHeights: [CGFloat] = [7, 13, 9, 5]

    // Widths and positions on half points keep the capsules crisp on Retina menu bars.
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 1.5
    private static let caretGap: CGFloat = 2
    private static let caretHeight: CGFloat = 15
    private static let serifWidth: CGFloat = 5
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
            // Silence leaves dots, so a recording never looks idle.
            let amount = CGFloat(step) / CGFloat(Variant.levelSteps - 1)
            return barHeights.map { barWidth + ($0 - barWidth) * amount }
        case .idle, .busy, .off:
            return barHeights
        }
    }

    private static func render(_ variant: Variant) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            let heights = heights(for: variant)
            let overhang = (serifWidth - barWidth) / 2
            let width = CGFloat(heights.count + 1) * barWidth + CGFloat(heights.count - 1) * gap + caretGap + overhang
            let left = ((rect.width - width) / 2 * 2).rounded() / 2
            var x = left
            let alpha: CGFloat = variant == .busy ? 0.45 : 1

            let shapes = NSBezierPath()
            for h in heights {
                shapes.append(capsule(NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)))
                x += barWidth + gap
            }
            x += caretGap - gap
            let bottom = rect.midY - caretHeight / 2
            shapes.append(capsule(NSRect(x: x, y: bottom, width: barWidth, height: caretHeight)))
            shapes.append(capsule(NSRect(x: x - overhang, y: bottom, width: serifWidth, height: barWidth)))
            shapes.append(capsule(NSRect(x: x - overhang, y: bottom + caretHeight - barWidth, width: serifWidth, height: barWidth)))
            NSColor.black.withAlphaComponent(alpha).setFill()
            shapes.fill()

            if variant == .off {
                drawSlash(across: NSRect(x: left, y: bottom, width: width, height: caretHeight))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func capsule(_ rect: NSRect) -> NSBezierPath {
        let radius = min(rect.width, rect.height) / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    // Corner to corner of the mark, so the cut never leaves a stub of a serif.
    private static func drawSlash(across mark: NSRect) {
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: mark.minX + 0.5, y: mark.maxY - 0.5))
        slash.line(to: NSPoint(x: mark.maxX - 0.5, y: mark.minY + 0.5))
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
