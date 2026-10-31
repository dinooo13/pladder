// Renders every picture of the Pladder mark from one geometry: four bars and a
// text caret, voice going in and text coming out where the cursor is.
// `Sources/Pladder/MenuBarIcon.swift` draws the same mark at menu bar size.
//
// Usage, from the repository root:
//   swift scripts/make-icon.swift [--font <Outfit[wght].ttf>]
// Writes the layers and colours of Assets/AppIcon.icon, which scripts/bundle.sh
// compiles with actool, then Assets/mark.svg, Assets/icon_1024.png,
// site/favicon.svg and site/apple-touch-icon.png. With --font it also writes
// the wordmark: Assets/wordmark.svg, Assets/logo.svg, Assets/logo-dark.svg,
// site/logo.svg and the social preview, in docs/images and site. The font is
// Outfit (SIL Open Font License 1.1), ofl/outfit/Outfit[wght].ttf in
// github.com/google/fonts at 5f24607; the wordmark is outlined so nothing
// that shows it needs the font.
import AppKit
import CoreText

let args = CommandLine.arguments
let fontPath = args.firstIndex(of: "--font").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - Geometry

// In the 1024-point canvas of an Icon Composer document, whose tile is the whole
// canvas. Every shape is symmetric about y = 512, so y-up and y-down agree.
enum Mark {
    static let barWidth: CGFloat = 80
    static let gap: CGFloat = 54
    // Wider than `gap`, so the caret's serifs keep clear of the last bar.
    static let caretGap: CGFloat = 68
    static let barHeights: [CGFloat] = [240, 464, 336, 192]
    static let caretHeight: CGFloat = 536
    static let serifWidth: CGFloat = 196

    static var overhang: CGFloat { (serifWidth - barWidth) / 2 }
    static var width: CGFloat {
        CGFloat(barHeights.count + 1) * barWidth + CGFloat(barHeights.count - 1) * gap + caretGap + overhang
    }
    static var left: CGFloat { (1024 - width) / 2 }

    static var bars: [CGRect] {
        barHeights.enumerated().map { i, h in
            CGRect(x: left + CGFloat(i) * (barWidth + gap), y: 512 - h / 2, width: barWidth, height: h)
        }
    }

    static var caret: [CGRect] {
        let stemX = left + CGFloat(barHeights.count) * (barWidth + gap) - gap + caretGap
        let top = 512 - caretHeight / 2
        return [
            CGRect(x: stemX, y: top, width: barWidth, height: caretHeight),
            CGRect(x: stemX - overhang, y: top, width: serifWidth, height: barWidth),
            CGRect(x: stemX - overhang, y: top + caretHeight - barWidth, width: serifWidth, height: barWidth),
        ]
    }
}

// One deep ink with a quiet top-to-bottom shift; the accent is on the caret only.
struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xff) / 255; g = CGFloat((hex >> 8) & 0xff) / 255; b = CGFloat(hex & 0xff) / 255
    }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
    var iconComposer: String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum Palette {
    static let inkTop = RGB(0x2B2F55)
    static let inkBottom = RGB(0x171933)
    static let darkTop = RGB(0x26272E)
    static let darkBottom = RGB(0x111115)
    static let paper = RGB(0xF5F5FA)
    static let accent = RGB(0xFF6A47)
}

// MARK: - SVG

func capsule(_ r: CGRect) -> String {
    let rx = min(r.width, r.height) / 2
    return "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"\(n(rx))\" ry=\"\(n(rx))\"/>"
}

func n(_ v: CGFloat) -> String {
    let rounded = (v * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
}

func pathData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(n(p[0].x)) \(n(p[0].y))"
        case .addLineToPoint: d += "L\(n(p[0].x)) \(n(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
        case .addCurveToPoint: d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

// The macOS tile: a rounded square with continuous corners, radius about 22% of the side.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let c = r.width * 0.2237, k: CGFloat = 0.552 * 1.28
    let (x0, x1, y0, y1) = (r.minX, r.maxX, r.minY, r.maxY)
    path.move(to: CGPoint(x: x0 + c, y: y0))
    path.addLine(to: CGPoint(x: x1 - c, y: y0))
    path.addCurve(to: CGPoint(x: x1, y: y0 + c), control1: CGPoint(x: x1 - c + c * k, y: y0), control2: CGPoint(x: x1, y: y0 + c - c * k))
    path.addLine(to: CGPoint(x: x1, y: y1 - c))
    path.addCurve(to: CGPoint(x: x1 - c, y: y1), control1: CGPoint(x: x1, y: y1 - c + c * k), control2: CGPoint(x: x1 - c + c * k, y: y1))
    path.addLine(to: CGPoint(x: x0 + c, y: y1))
    path.addCurve(to: CGPoint(x: x0, y: y1 - c), control1: CGPoint(x: x0 + c - c * k, y: y1), control2: CGPoint(x: x0, y: y1 - c + c * k))
    path.addLine(to: CGPoint(x: x0, y: y0 + c))
    path.addCurve(to: CGPoint(x: x0 + c, y: y0), control1: CGPoint(x: x0, y: y0 + c - c * k), control2: CGPoint(x: x0 + c - c * k, y: y0))
    path.closeSubpath()
    return path
}

let barsSVG = Mark.bars.map(capsule).joined()
let caretSVG = Mark.caret.map(capsule).joined()

// The tile, the bars and the caret, flat: what the icon is without the system's glass.
func flatMark(id: String) -> String {
    """
    <defs><linearGradient id="\(id)" x1="0" y1="0" x2="0" y2="1">\
    <stop offset="0" stop-color="\(Palette.inkTop.hex)"/><stop offset="1" stop-color="\(Palette.inkBottom.hex)"/>\
    </linearGradient></defs>\
    <path fill="url(#\(id))" d="\(pathData(squircle(CGRect(x: 0, y: 0, width: 1024, height: 1024))))"/>\
    <g fill="\(Palette.paper.hex)">\(barsSVG)</g><g fill="\(Palette.accent.hex)">\(caretSVG)</g>
    """
}

func svg(width: CGFloat, height: CGFloat, _ body: String, label: String? = nil) -> String {
    let a11y = label.map { " role=\"img\" aria-label=\"\($0)\"" } ?? ""
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(n(width)) \(n(height))\"\(a11y)>\(body)</svg>\n"
}

func write(_ text: String, _ path: String) {
    let url = root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(path)")
}

// MARK: - Icon Composer document

let iconDir = "Assets/AppIcon.icon"
write(svg(width: 1024, height: 1024, "<g fill=\"\(Palette.paper.hex)\">\(barsSVG)</g>"), "\(iconDir)/Assets/bars.svg")
write(svg(width: 1024, height: 1024, "<g fill=\"\(Palette.accent.hex)\">\(caretSVG)</g>"), "\(iconDir)/Assets/caret.svg")

func gradient(_ top: RGB, _ bottom: RGB) -> [String: Any] {
    ["linear-gradient": [top.iconComposer, bottom.iconComposer],
     "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]]
}
func layer(_ name: String) -> [String: Any] {
    ["name": name, "image-name": "\(name).svg", "glass": true]
}
let document: [String: Any] = [
    "fill-specializations": [
        ["value": gradient(Palette.inkTop, Palette.inkBottom)],
        ["appearance": "dark", "value": gradient(Palette.darkTop, Palette.darkBottom)],
    ],
    "groups": [[
        "layers": [layer("caret"), layer("bars")],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "specular": true,
        "translucency": ["enabled": true, "value": 0.5],
    ]],
    "supported-platforms": ["squares": "shared"],
]
let json = try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
write(String(decoding: json, as: UTF8.self) + "\n", "\(iconDir)/icon.json")

// MARK: - Flat marks

write(svg(width: 1024, height: 1024, flatMark(id: "ink"), label: "Pladder"), "Assets/mark.svg")
write(svg(width: 1024, height: 1024, flatMark(id: "ink"), label: "Pladder"), "site/favicon.svg")

// MARK: - Renders of the glass icon

func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "\(tool) failed")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// Icon Composer's renderer, which draws the glass the way the system does.
let ictool = run("/usr/bin/xcode-select", ["-p"])
    + "/../Applications/Icon Composer.app/Contents/Executables/ictool"

func exportIcon(_ path: String, platform: String, size: Int) {
    _ = run(ictool, [root.appendingPathComponent(iconDir).path, "--export-image",
                     "--output-file", root.appendingPathComponent(path).path,
                     "--platform", platform, "--rendition", "Default",
                     "--width", "\(size)", "--height", "\(size)", "--scale", "1"])
    print("wrote \(path)")
}
exportIcon("Assets/icon_1024.png", platform: "macOS", size: 1024)
// Square and opaque: iOS rounds the corners itself.
exportIcon("site/apple-touch-icon.png", platform: "iOS", size: 180)

// MARK: - Wordmark

guard let fontPath else { exit(0) }

let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as! [CTFontDescriptor]
func outfit(_ weight: CGFloat, _ size: CGFloat) -> CTFont {
    let wght = 0x7767_6874 as CFNumber
    return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithVariation(descriptors[0], wght, weight), size, nil)
}

// Glyph outlines of a line of text, y up, baseline at 0.
func outline(_ text: String, font: CTFont, tracking: CGFloat = 0) -> CGPath {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        for (glyph, position) in zip(glyphs, positions) {
            guard let shape = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
            path.addPath(shape, transform: CGAffineTransform(translationX: position.x, y: position.y))
        }
    }
    return path
}

let wordmarkFont = outfit(600, 200)
let word = outline("Pladder", font: wordmarkFont, tracking: -2)
let wordBox = word.boundingBoxOfPath

// The same outline in the SVG's y-down space, its box at the origin.
func flipped(_ path: CGPath, box: CGRect, to origin: CGPoint) -> CGPath {
    var t = CGAffineTransform(translationX: origin.x - box.minX, y: origin.y + box.maxY).scaledBy(x: 1, y: -1)
    return path.copy(using: &t)!
}

write(svg(width: wordBox.width, height: wordBox.height,
          "<path fill=\"\(Palette.inkBottom.hex)\" d=\"\(pathData(flipped(word, box: wordBox, to: .zero)))\"/>",
          label: "Pladder"), "Assets/wordmark.svg")

// The lockup: the mark at 1024, the wordmark's box centred on it and as tall as
// the caret, so the ascenders of "l" and "d" line up with the serifs.
let wordScale = Mark.caretHeight / wordBox.height
let lockupGap: CGFloat = 176
let lockupWidth = 1024 + lockupGap + wordBox.width * wordScale
var placement = CGAffineTransform(translationX: 1024 + lockupGap, y: 512 + Mark.caretHeight / 2)
    .scaledBy(x: wordScale, y: -wordScale)
    .translatedBy(x: -wordBox.minX, y: -wordBox.minY)
let placedWord = pathData(word.copy(using: &placement)!)
for (name, color) in [("logo", Palette.inkBottom), ("logo-dark", Palette.paper)] {
    let body = flatMark(id: "ink") + "<path fill=\"\(color.hex)\" d=\"\(placedWord)\"/>"
    write(svg(width: lockupWidth, height: 1024, body, label: "Pladder"), "Assets/\(name).svg")
}
write(svg(width: lockupWidth, height: 1024, flatMark(id: "ink") + "<path fill=\"\(Palette.paper.hex)\" d=\"\(placedWord)\"/>",
          label: "Pladder"), "site/logo.svg")

// MARK: - Social preview

// GitHub's size for a repository's social image; it caps the upload at 1 MB.
let social = CGSize(width: 1280, height: 640)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(social.width), height: Int(social.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let background = CGGradient(colorsSpace: srgb, colors: [Palette.inkTop.cg, Palette.inkBottom.cg] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: social.height), end: .zero, options: [])

let iconImage = NSImage(contentsOf: root.appendingPathComponent("Assets/icon_1024.png"))!
    .cgImage(forProposedRect: nil, context: nil, hints: nil)!
let iconSize: CGFloat = 196
let socialWordScale = iconSize * Mark.caretHeight / 1024 / wordBox.height
let rowWidth = iconSize + 44 + wordBox.width * socialWordScale
let rowLeft = (social.width - rowWidth) / 2
let rowMid: CGFloat = 392
ctx.draw(iconImage, in: CGRect(x: rowLeft, y: rowMid - iconSize / 2, width: iconSize, height: iconSize))
ctx.saveGState()
ctx.translateBy(x: rowLeft + iconSize + 44, y: rowMid - iconSize * Mark.caretHeight / 1024 / 2)
ctx.scaleBy(x: socialWordScale, y: socialWordScale)
ctx.translateBy(x: -wordBox.minX, y: -wordBox.minY)
ctx.addPath(word)
ctx.setFillColor(Palette.paper.cg)
ctx.fillPath()
ctx.restoreGState()

func centred(_ text: String, font: CTFont, alpha: CGFloat, baseline: CGFloat) {
    let path = outline(text, font: font)
    let box = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.translateBy(x: (social.width - box.width) / 2 - box.minX, y: baseline)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: Palette.paper.r, green: Palette.paper.g, blue: Palette.paper.b, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}
centred("Talk to your agents.", font: outfit(500, 52), alpha: 0.95, baseline: 196)
centred("Push-to-talk dictation for macOS. On-device, free and open source.", font: outfit(400, 30), alpha: 0.62, baseline: 136)

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
for path in ["docs/images/social-preview.png", "site/social-preview.png"] {
    try! png.write(to: root.appendingPathComponent(path))
    print("wrote \(path)")
}
