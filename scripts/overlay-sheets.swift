// Cuts the contact sheets for scripts/overlay-demo.sh: one per path, from
// just before the release to the end of the fly-out, cropped to the bottom
// centre of the main display where the pill shows.
//
// Usage: swift scripts/overlay-sheets.swift <dir> <epoch the recording stopped>
import AppKit
import AVFoundation

let dir = URL(filePath: CommandLine.arguments[1])
let stopped = Double(CommandLine.arguments[2])!
let asset = AVURLAsset(url: dir.appending(path: "demo.mov"))
let started = stopped - (try await asset.load(.duration).seconds)

// "<epoch> <path> <event>" per line, then "<epoch> done".
struct Event { let time: Double; let name: String }
var paths: [(name: String, events: [Event])] = []
let log = try String(contentsOf: dir.appending(path: "demo.log"), encoding: .utf8)
for line in log.split(separator: "\n") {
    let parts = line.split(separator: " ")
    guard parts.count == 3, let time = Double(parts[0]) else { continue }
    let path = String(parts[1])
    if paths.last?.name != path { paths.append((path, [])) }
    paths[paths.count - 1].events.append(Event(time: time - started, name: String(parts[2])))
}

let screen = NSScreen.main!.frame
// Room for the widest pill (Live Transcript's 440 pt) and its panel, which
// rests 64 pt above the bottom edge and dives through it.
let crop = CGSize(width: 520, height: 230)
let step = 1.0 / 15
let columns = 5
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

for path in paths {
    guard let release = path.events.first(where: { $0.name == "release" }),
          let idle = path.events.last(where: { $0.name == "idle" }) else { continue }
    // The release and the end, and whatever lies between only if it is short:
    // a polish pass is seconds of the same Polishing row.
    var times: [Double] = []
    let opening = stride(from: release.time - 0.1, to: release.time + 1.0, by: step)
    let closing = stride(from: idle.time - 0.1, to: idle.time + 1.2, by: step)
    times += opening
    times += closing.filter { $0 > (times.last ?? 0) }

    var tiles: [(CGImage, String)] = []
    for time in times {
        guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        else { continue }
        let scale = CGFloat(frame.width) / screen.width
        let rect = CGRect(
            x: (screen.width - crop.width) / 2 * scale,
            y: (screen.height - crop.height) * scale,
            width: crop.width * scale,
            height: crop.height * scale)
        let state = path.events.last(where: { $0.time <= time })?.name ?? ""
        tiles.append((frame.cropping(to: rect)!, String(format: "%+.2f s  %@", time - release.time, state)))
    }

    let label: CGFloat = 16
    let rows = (tiles.count + columns - 1) / columns
    let size = CGSize(width: crop.width * CGFloat(columns), height: (crop.height + label) * CGFloat(rows))
    // At 1x: a retina sheet is four times the pixels and no easier to read.
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    CGRect(origin: .zero, size: size).fill()
    for (index, (image, text)) in tiles.enumerated() {
        let x = CGFloat(index % columns) * crop.width
        let y = size.height - CGFloat(index / columns + 1) * (crop.height + label)
        NSImage(cgImage: image, size: crop).draw(in: CGRect(x: x, y: y, width: crop.width, height: crop.height))
        (text as NSString).draw(
            at: CGPoint(x: x + 4, y: y + crop.height + 1),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
    }
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let url = dir.appending(path: "sheet-\(path.name).png")
    try png.write(to: url)
    print(url.path)
}
