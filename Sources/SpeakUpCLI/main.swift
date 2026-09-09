@preconcurrency import AVFoundation
import Foundation
import SpeakUpAudio
import SpeakUpCore
import SpeakUpEngines

// Developer tool: `speakup-cli <audio file>` loads Parakeet and prints the
// transcript. Used to verify the engine without the GUI.

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"]) }
    try file.read(into: input)
    let target = try AudioResampler.monoFloat32Format()
    return try AudioResampler.convert(input, to: target)
}

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    FileHandle.standardError.write(Data("usage: speakup-cli <audio file>\n".utf8))
    exit(2)
}

let engine = FluidAudioEngine()
let started = Date()
var lastPrinted = -1
let statusTask = Task {
    while !Task.isCancelled {
        if case .downloading(let p) = await engine.status, let p {
            let pct = Int(p * 100)
            if pct != lastPrinted { print("downloading \(pct)%"); lastPrinted = pct }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
try await engine.load()
statusTask.cancel()
print(String(format: "model ready in %.1fs", Date().timeIntervalSince(started)))

let samples = try loadSamples(URL(fileURLWithPath: path))
let transcript = try await engine.transcribe(samples)
print(String(format: "audio %.2fs, processed in %.3fs (%.0fx realtime)", transcript.audioDuration, transcript.processingTime, transcript.realtimeFactor))
print("TEXT: \(transcript.text)")
