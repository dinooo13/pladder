import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI
import PladderCore

// `--screenshots <dir> --hero-video`: the site's hero as a film of one dictation, the real
// window and pill animating through it, recorded with ScreenCaptureKit from that one
// window only, so nothing else on the screen is ever captured.
@MainActor
enum HeroRecording {
    static func run(into directory: URL) async {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            do {
                try await record(scheme: scheme, to: directory.appending(path: "hero-film-\(suffix).mov"))
                print("wrote hero-film-\(suffix).mov")
            } catch {
                print("hero video: \(error)")
            }
        }
    }

    private static func record(scheme: ColorScheme, to url: URL) async throws {
        let scene = HeroScene()
        let size = HeroFigure.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: HeroFigure(scene: scene)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
        window.center()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(700))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.featureUnsupported)
        }
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2)
        config.height = Int(size.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let writer = try FilmWriter(url: url, width: config.width, height: config.height)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        await scene.play()
        try await stream.stopCapture()
        await writer.finish()
    }
}

// One dictation, timed as the app times it: the pill appears after the 150 ms present
// delay, the words arrive in passes, and the paste lands about 0.2 s after the release.
@MainActor
@Observable
final class HeroScene {
    var composer: String?
    var showsPill = false
    var presentation: OverlayPresentation = .flyingIn
    var partial: String?
    var level: Float = 0

    func play() async {
        await pause(0.4)
        // The row rises in; the panel's flight from the screen's edge has no edge to come
        // from in a picture of one window.
        presentation = .settled
        showsPill = true
        await pause(OverlayMotion.flightDuration)
        let passes: [(Double, String?)] = [(0.55, nil), (0.45, "yes, and"), (0.45, "yes, and add a test"), (0.55, "yes, and add a test for it")]
        for (seconds, words) in passes {
            partial = words
            await speak(for: seconds)
        }
        level = 0
        presentation = .flyingOut
        await pause(OverlayMotion.morphDuration)
        showsPill = false
        await pause(0.2 - OverlayMotion.morphDuration + 0.2)
        composer = "Yes, and add a test for it."
        await pause(1.2)
    }

    // A speaking voice's level, so the bars move as they do on a real take.
    private func speak(for seconds: Double) async {
        let start = Date()
        var t = 0.0
        while Date().timeIntervalSince(start) < seconds {
            level = Float(0.35 + 0.3 * abs(sin(t * 2.3)) + 0.15 * abs(sin(t * 7.1)))
            t += 0.05
            await pause(0.05)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

// Appends ScreenCaptureKit's frames to an H.264 movie as they come; frames arrive only
// when something changed, and their own timestamps keep the timing right.
private final class FilmWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "de.dinooo13.pladder.hero-film")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var last: CMSampleBuffer?

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, Self.isComplete(buffer) else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
        last = buffer
    }

    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                // To now, on the capture's own host clock: an unchanged window sends no frames,
                // so the last one is held to the end of the scene.
                if self.last != nil { self.writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock())) }
                self.input.markAsFinished()
                self.writer.finishWriting { done.resume() }
            }
        }
    }
}
