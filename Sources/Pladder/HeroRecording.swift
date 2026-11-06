import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI
import PladderCore

// `--screenshots <dir> --hero-video`: the site's hero as a film of one dictation, the real
// window and pill animating through it, recorded with ScreenCaptureKit from that one
// window only: the filter includes no other window and the frame is cropped to it, so
// nothing else on the screen is ever captured.
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
        // The display's composite, limited to this one window and cropped to it: a
        // desktop-independent capture of the window missed the glass mid-morph, which the
        // window server draws only on the composited screen.
        guard let display = content.displays.first(where: { $0.frame.contains(window.frame.origin) }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? display.frame.height
        config.sourceRect = CGRect(
            x: window.frame.minX - display.frame.minX,
            y: screenHeight - window.frame.maxY - display.frame.minY,
            width: size.width, height: size.height)
        let filter = SCContentFilter(display: display, including: [target])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        await scene.play()
        try await stream.stopCapture()
        await writer.finish()
    }
}

// One dictation, timed as the app times it: the pill rises in, the words arrive in
// passes, and at the release the row gathers into the disc while the reply is pasted
// 0.2 s later, before the disc dives. The pill is the app's own `OverlayView` on its own
// `OverlayModel`, so every morph and fade is the one the panel shows.
@MainActor
@Observable
final class HeroScene {
    var composer: String?
    let overlay: OverlayModel = {
        let model = OverlayModel()
        model.style = .liveTranscript
        model.presentation = .settled
        return model
    }()
    // The panel's own motion, which the window stands in for: rising in, diving out.
    var pillOffset: CGFloat = 24
    var pillOpacity: Double = 0

    func play() async {
        await pause(0.4)
        overlay.state = .recording
        withAnimation(.easeOut(duration: OverlayMotion.flightDuration)) {
            pillOffset = 0
            pillOpacity = 1
        }
        await pause(OverlayMotion.flightDuration)
        let passes: [(Double, String?)] = [(0.55, nil), (0.45, "yes, and"), (0.45, "yes, and add a test"), (0.55, "yes, and add a test for it")]
        for (seconds, words) in passes {
            overlay.partialTranscript = words
            await speak(for: seconds)
        }
        // The release: the row gathers, the paste lands 0.2 s in, then the disc dives.
        overlay.presentation = .flyingOut
        await pause(0.2)
        composer = "Yes, and add a test for it."
        await pause(OverlayMotion.morphDuration - 0.2)
        withAnimation(.easeIn(duration: OverlayMotion.flightDuration)) {
            pillOffset = 60
            pillOpacity = 0
        }
        await pause(OverlayMotion.flightDuration + 1.4)
    }

    // A speaking voice's level, so the bars move as they do on a real take.
    private func speak(for seconds: Double) async {
        let start = Date()
        var t = 0.0
        while Date().timeIntervalSince(start) < seconds {
            overlay.level = Float(0.35 + 0.3 * abs(sin(t * 2.3)) + 0.15 * abs(sin(t * 7.1)))
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
