@preconcurrency import AVFoundation
import Foundation
import SpeakUpAudio
import SpeakUpCore
import SpeakUpEngines
import SpeakUpSystem

// Developer tool with two modes:
//   speakup-cli <audio file>                  loads Parakeet and prints the
//                                              transcript, to verify the
//                                              engine without the GUI.
//   speakup-cli --tidy <fixtures file> [--cold]
//                                              runs the Apple Intelligence
//                                              tidy pass over one raw
//                                              transcript per line and prints
//                                              a side-by-side review. Manual
//                                              tool, not run in CI: it needs
//                                              Apple Intelligence on the
//                                              machine.

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"]) }
    try file.read(into: input)
    let target = try AudioResampler.monoFloat32Format()
    return try AudioResampler.convert(input, to: target)
}

func runTranscribe(_ path: String) async throws {
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
}

// MARK: - Tidy review

extension Duration {
    fileprivate var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}

/// Formats a rejection exactly as the spec's worked example:
/// `wordCountDrift(expected: 27, actual: 41)`.
private func describe(_ rejection: TidyAcceptance.Rejection) -> String {
    switch rejection {
    case .empty: return "empty"
    case .tooLong: return "tooLong"
    case .wordCountDrift(let expected, let actual):
        return "wordCountDrift(expected: \(expected), actual: \(actual))"
    case .contentLost(let retained):
        return "contentLost(retained: \(String(format: "%.2f", retained)))"
    }
}

private func describe(_ reason: FoundationModelProcessor.Report.Reason) -> String {
    switch reason {
    case .unavailable: return "unavailable"
    case .blank: return "blank"
    case .modelError(let message): return "model error: \(message)"
    case .timeout: return "timeout"
    case .overBudget: return "over budget"
    case .rejected(let first, let retry):
        if let retry {
            return "rejected \(describe(first)), retry \(describe(retry))"
        }
        return "rejected \(describe(first))"
    }
}

/// Full verdict text for a single-chunk line, e.g. `accepted` or
/// `raw (rejected wordCountDrift(expected: 27, actual: 41), retry contentLost(retained: 0.74))`.
private func describe(_ outcome: FoundationModelProcessor.Report.Outcome) -> String {
    switch outcome {
    case .accepted: return "accepted"
    case .rescued(let first): return "rescued (first \(describe(first)))"
    case .raw(let reason): return "raw (\(describe(reason)))"
    }
}

/// Short reason tag used in the per-chunk summary of a multi-chunk line,
/// e.g. `raw(timeout)`.
private func shortReasonTag(_ reason: FoundationModelProcessor.Report.Reason) -> String {
    switch reason {
    case .unavailable: return "unavailable"
    case .blank: return "blank"
    case .modelError: return "modelError"
    case .timeout: return "timeout"
    case .overBudget: return "overBudget"
    case .rejected: return "rejected"
    }
}

private func shortDescribe(_ outcome: FoundationModelProcessor.Report.Outcome) -> String {
    switch outcome {
    case .accepted: return "accepted"
    case .rescued: return "rescued"
    case .raw(let reason): return "raw(\(shortReasonTag(reason)))"
    }
}

func runTidy(_ arguments: [String]) async throws {
    var cold = false
    var path: String?
    for argument in arguments {
        if argument == "--cold" {
            cold = true
        } else if path == nil {
            path = argument
        }
    }
    guard let path else {
        FileHandle.standardError.write(Data("usage: speakup-cli --tidy <fixtures file> [--cold]\n".utf8))
        exit(2)
    }

    if let reason = FoundationModelProcessor.availability {
        print(reason)
        exit(1)
    }

    let content = try String(contentsOfFile: path, encoding: .utf8)
    let lines = content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

    var lineElapsedMillis: [Double] = []
    var allChunkOutcomes: [FoundationModelProcessor.Report.Outcome] = []

    for (offset, line) in lines.enumerated() {
        let index = offset + 1
        let processor = FoundationModelProcessor()
        if !cold {
            await processor.prepare()
            try? await Task.sleep(for: .milliseconds(300))
        }
        let report = await processor.tidy(line)

        let words = line.split { $0.isWhitespace }.count
        let ms = report.elapsed.milliseconds
        let verdict: String
        if report.chunks.count <= 1 {
            verdict = describe(report.chunks.first?.outcome ?? .raw(.blank))
        } else {
            verdict = "chunks: " + report.chunks.map { shortDescribe($0.outcome) }.joined(separator: ", ")
        }

        print("[\(index)] \(words) words, \(Int(ms.rounded())) ms, \(verdict)")
        print("raw:  \(line)")
        print("tidy: \(report.text)")
        for candidate in report.chunks.flatMap(\.rejected) {
            print("dropped: \(candidate)")
        }
        print("")

        lineElapsedMillis.append(ms)
        allChunkOutcomes.append(contentsOf: report.chunks.map(\.outcome))

    }

    var accepted = 0
    var rescued = 0
    var rawReasons: [String: Int] = [:]
    for outcome in allChunkOutcomes {
        switch outcome {
        case .accepted: accepted += 1
        case .rescued: rescued += 1
        case .raw(let reason): rawReasons[shortReasonTag(reason), default: 0] += 1
        }
    }
    let rawTotal = rawReasons.values.reduce(0, +)

    let sorted = lineElapsedMillis.sorted()
    let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    let median: Double
    if sorted.isEmpty {
        median = 0
    } else if sorted.count % 2 == 1 {
        median = sorted[sorted.count / 2]
    } else {
        median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    print("Summary: \(lines.count) lines")
    print("  accepted: \(accepted)")
    print("  rescued: \(rescued)")
    if rawTotal > 0 {
        let breakdown = rawReasons.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        print("  raw: \(rawTotal) (\(breakdown))")
    } else {
        print("  raw: 0")
    }
    print("  mean \(Int(mean.rounded())) ms, median \(Int(median.rounded())) ms")
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--tidy" {
    try await runTidy(Array(arguments.dropFirst()))
} else if let path = arguments.first {
    try await runTranscribe(path)
} else {
    FileHandle.standardError.write(Data("usage: speakup-cli <audio file>\n       speakup-cli --tidy <fixtures file> [--cold]\n".utf8))
    exit(2)
}
