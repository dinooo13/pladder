import AppKit
import PladderCore

// A template image, so it takes the menu bar's tint. The four bars and the
// caret are `scripts/make-icon.swift`'s mark, scaled to a 15 pt caret and
// rounded to whole and half points.
enum MenuBarIcon {
    // Few enough to cache every variant, so the label follows the level without redrawing.
    enum Variant: Hashable {
        case idle
        // Quantised, so the image cache stays bounded. `tile`: knocked out of a filled tile.
        case recording(step: Int, tile: Bool = false)
        case busy
        case off

        static let levelSteps = 6

        init(state: DictationState, level: Float, tile: Bool = false) {
            switch state {
            // The clipboard hint is neither failure nor work: the overlay carries the message.
            case .idle, .copied: self = .idle
            case .recording:
                let amp = CGFloat(WaveformMeter.amplitude(for: level))
                self = .recording(step: Int((amp * CGFloat(Self.levelSteps - 1)).rounded()), tile: tile)
            // A dictation on its way out is a fraction of a second: dimming for it would blink
            // the icon to "off" after every take. Starting, loading and the first download are
            // work, not failure, so they dim rather than slash.
            case .transcribing, .polishing, .inserting: self = .idle
            case .unavailable(.starting), .unavailable(.loadingModel): self = .busy
            case .unavailable(.engineFailed), .error: self = .off
            }
        }
    }

    // Widths and positions on half points keep the capsules crisp on Retina menu bars.
    private struct Geometry {
        var barHeights: [CGFloat]
        var barWidth: CGFloat
        var gap: CGFloat
        var caretGap: CGFloat
        var caretHeight: CGFloat
        var serifWidth: CGFloat
    }

    private static let plain = Geometry(
        barHeights: [7, 13, 9, 5], barWidth: 2, gap: 1.5, caretGap: 2, caretHeight: 15, serifWidth: 5)
    // Inside the recording tile, drawn at its own half-point sizes rather than scaled down,
    // with about 2 pt of tile around it.
    private static let knockout = Geometry(
        barHeights: [4.5, 9, 6, 3.5], barWidth: 1.5, gap: 1, caretGap: 1.5, caretHeight: 10, serifWidth: 3.5)
    private static let canvas = NSSize(width: 22, height: 16)

    @MainActor private static var cache: [Variant: NSImage] = [:]

    @MainActor
    static func image(for state: DictationState, level: Float = 0, tile: Bool = false) -> NSImage {
        image(for: Variant(state: state, level: level, tile: tile))
    }

    @MainActor
    static func image(for variant: Variant) -> NSImage {
        if let cached = cache[variant] { return cached }
        let image = render(variant)
        cache[variant] = image
        return image
    }

    private static func heights(for variant: Variant, in g: Geometry) -> [CGFloat] {
        switch variant {
        case .recording(let step, _):
            // Silence leaves dots, so a recording never looks idle. Rounded to half points.
            let amount = CGFloat(step) / CGFloat(Variant.levelSteps - 1)
            return g.barHeights.map { ((g.barWidth + ($0 - g.barWidth) * amount) * 2).rounded() / 2 }
        case .idle, .busy, .off:
            return g.barHeights
        }
    }

    private static func render(_ variant: Variant) -> NSImage {
        let tiled: Bool = { if case .recording(_, true) = variant { return true }; return false }()
        let g = tiled ? knockout : plain
        let image = NSImage(size: canvas, flipped: false) { rect in
            let heights = heights(for: variant, in: g)
            let overhang = (g.serifWidth - g.barWidth) / 2
            let width = CGFloat(heights.count + 1) * g.barWidth + CGFloat(heights.count - 1) * g.gap + g.caretGap + overhang
            let left = ((rect.width - width) / 2 * 2).rounded() / 2
            var x = left
            let alpha: CGFloat = variant == .busy ? 0.45 : 1

            let shapes = NSBezierPath()
            for h in heights {
                shapes.append(capsule(NSRect(x: x, y: rect.midY - h / 2, width: g.barWidth, height: h)))
                x += g.barWidth + g.gap
            }
            x += g.caretGap - g.gap
            let bottom = rect.midY - g.caretHeight / 2
            shapes.append(capsule(NSRect(x: x, y: bottom, width: g.barWidth, height: g.caretHeight)))
            shapes.append(capsule(NSRect(x: x - overhang, y: bottom, width: g.serifWidth, height: g.barWidth)))
            shapes.append(capsule(NSRect(x: x - overhang, y: bottom + g.caretHeight - g.barWidth, width: g.serifWidth, height: g.barWidth)))
            if tiled {
                // Knocked out of a filled tile, as the system's own recording glyphs are, so the
                // menu bar says "recording" at a glance when it is the only signal.
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                shapes.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                return true
            }
            NSColor.black.withAlphaComponent(alpha).setFill()
            shapes.fill()

            if variant == .off {
                drawSlash(across: NSRect(x: left, y: bottom, width: width, height: g.caretHeight))
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
