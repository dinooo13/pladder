// Renders the Pladder app icon: a deep blue-to-violet squircle with a white
// voice waveform, echoing the level meter in the dictation pill.
// Usage: swift scripts/make-icon.swift <output-dir>   (writes icon_1024.png)
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

func squirclePath(in rect: CGRect) -> CGPath {
    // macOS icon shape: continuous-curvature rounded rect, radius ~22.4% of side.
    let path = CGMutablePath()
    let r = rect.width * 0.224
    let k: CGFloat = 0.552 * 1.28   // pulled-in control points for a superellipse feel
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + r), control1: CGPoint(x: maxX - r + r * k, y: minY), control2: CGPoint(x: maxX, y: minY + r - r * k))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(to: CGPoint(x: maxX - r, y: maxY), control1: CGPoint(x: maxX, y: maxY - r + r * k), control2: CGPoint(x: maxX - r + r * k, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - r), control1: CGPoint(x: minX + r - r * k, y: maxY), control2: CGPoint(x: minX, y: maxY - r + r * k))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(to: CGPoint(x: minX + r, y: minY), control1: CGPoint(x: minX, y: minY + r - r * k), control2: CGPoint(x: minX + r - r * k, y: minY))
    path.closeSubpath()
    return path
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icons leave a transparent margin; the visible tile is ~82% of the canvas.
let inset = size * 0.09
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = squirclePath(in: tile)

// Drop shadow like Apple's template.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep indigo at the bottom to electric blue-violet at the top.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 1),
    CGColor(red: 0.18, green: 0.20, blue: 0.62, alpha: 1),
    CGColor(red: 0.07, green: 0.08, blue: 0.30, alpha: 1),
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

// Soft radial glow behind the waveform.
let glow = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.6, green: 0.7, blue: 1, alpha: 0.35),
    CGColor(red: 0.6, green: 0.7, blue: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.midY + tile.height * 0.05), startRadius: 0,
                       endCenter: CGPoint(x: tile.midX, y: tile.midY), endRadius: tile.width * 0.55, options: [])

// Top-edge highlight for a glassy rim.
let rim = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.maxY - tile.height * 0.35), options: [])
ctx.restoreGState()

// Waveform: nine capsules with a bell-shaped envelope, like the level meter.
let heights: [CGFloat] = [0.20, 0.36, 0.58, 0.82, 1.0, 0.82, 0.58, 0.36, 0.20]
let barW = tile.width * 0.058
let gap = tile.width * 0.036
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let maxH = tile.height * 0.50
var x = tile.midX - totalW / 2
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.02, color: CGColor(gray: 0, alpha: 0.25))
for h in heights {
    let barH = maxH * h
    let rect = CGRect(x: x, y: tile.midY - barH / 2, width: barW, height: barH)
    let capsule = CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.addPath(capsule)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()
    x += barW + gap
}
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png"))
print("wrote \(outDir)/icon_1024.png")
