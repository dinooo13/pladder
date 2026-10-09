import Foundation
import PladderBench
import PladderCore
import PladderEngines
import PladderRefine
import PladderSystem

extension PolishModel {
    /// The name `--model` takes for this model. A `switch` without a
    /// `default`, so a new case does not compile until it has a name here.
    var cliName: String {
        switch self {
        case .appleIntelligence: "apple"
        case .s1Mini: "s1-mini"
        case .s1Mini8Bit: "s1-mini-8bit"
        }
    }

    /// Every `--model` name, as the usage line lists them.
    static var cliNames: String {
        allCases.map(\.cliName).joined(separator: "|")
    }

    init?(cliName: String) {
        guard let model = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = model
    }
}

/// Runs `TranscriptPolisher` over one transcript twice and prints what the
/// polish toggle would paste. The first run is cold (no `prepare()`), the second
/// warm, which is what a real press gets: the session is made and prewarmed
/// at key-down, seconds before the release.
func runPolish(_ path: String, model: PolishModel, options: PolishOptions) async throws {
    let text: String
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }
    let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if model == .appleIntelligence {
        print("availability: \(TranscriptPolisher.availability)")
    }
    print("input (\(transcript.split(whereSeparator: \.isWhitespace).count) words):")
    print(transcript)

    func show(_ label: String, _ report: TranscriptPolisher.Report) {
        print("")
        let timing = String(format: "%.3f", report.elapsed.timeInterval)
        if let polished = report.text {
            print("\(label): \(timing) s, \(report.wordsIn) words in, \(report.wordsOut) out, \(report.mode.rawValue)")
            print(polished)
        } else {
            let reason = report.failure ?? "unknown"
            print("\(label): \(timing) s, no polish (\(reason)); the text would be pasted as dictated")
        }
    }

    let polisher = try await makePolisher(model, options: options)
    show("cold", await polisher.polish(transcript))
    await polisher.prepare()
    try await Task.sleep(for: .seconds(2))
    show("warm", await polisher.polish(transcript))
}

/// Either polisher behind one face, for the CLI: both report the same way.
struct CLIPolisher {
    let polish: @Sendable (String) async -> TranscriptPolisher.Report
    let prepare: @Sendable () async -> Void
}

/// What the command line changes about a polisher; nil is the app's own.
struct PolishOptions {
    var instructionsPath: String?
    var gguf: String?
    var control: String?
}

/// The polisher the app would use for `model`, downloading an S1-mini file
/// into the app's own model directory first if it is not there yet. With
/// `--gguf`, an S1-mini polisher over that file instead.
func makePolisher(_ model: PolishModel, options: PolishOptions = PolishOptions()) async throws -> CLIPolisher {
    let instructionsPath = options.instructionsPath
    if let gguf = options.gguf {
        if instructionsPath != nil { usage() }
        let url = URL(fileURLWithPath: gguf)
        let file = ModelFile(fileName: url.lastPathComponent, url: url, sha256: "", byteCount: 0)
        let polisher = S1MiniPolisher(file: file, location: url, control: options.control ?? S1MiniPolisher.controlLine)
        print("model: \(gguf)")
        if let control = options.control { print("control: \(control)") }
        return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
    }
    guard let file = ModelFile(for: model) else {
        if options.control != nil { usage() }
        let polisher: TranscriptPolisher
        if let instructionsPath {
            let instructions = try String(contentsOf: URL(fileURLWithPath: instructionsPath), encoding: .utf8)
            polisher = TranscriptPolisher(instructions: instructions)
            print("instructions: \(instructionsPath)")
        } else {
            polisher = TranscriptPolisher()
        }
        return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
    }
    if instructionsPath != nil { usage() }
    let files = ModelFiles(directory: ModelFiles.defaultDirectory) { _, status in
        if case .downloading(let fraction) = status {
            eprint(String(format: "\rdownloading %3.0f%%", fraction * 100), terminator: "")
        } else if status == .verifying {
            eprint("\rverifying          ")
        }
    }
    await files.ensure(file)
    let status = await files.finished(file)
    guard status == .ready else {
        eprint("\(file.fileName): \(status)")
        exit(1)
    }
    let polisher = S1MiniPolisher(
        file: file, location: files.location(of: file), control: options.control ?? S1MiniPolisher.controlLine)
    print("model: \(file.fileName)")
    if let control = options.control { print("control: \(control)") }
    return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
}

/// One case of a polish test set: what the speech model heard and what
/// should be pasted.
struct PolishCase: Decodable {
    let id: String
    let lang: String
    let input: String
    let expected: String
}

/// Runs `model` over a test set the way the app would: the app's processors
/// first, then the polish, warm. Prints every answer, then per-language word
/// error rates against the expected text (case and punctuation ignored),
/// exact matches (everything counts) and the polish time.
func runPolishSet(_ path: String, model: PolishModel, options: PolishOptions) async throws {
    let cases = try JSONDecoder().decode([PolishCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard !cases.isEmpty else {
        eprint("pladder-cli: \(path): the test set has no cases")
        exit(1)
    }
    // The processors `--process` runs, with a fresh install's settings: no
    // dictionary, so the set means the same on every machine.
    let pipeline = StandardProcessors.pipeline(for: DictationSettings(engineID: StandardEngines.defaultEntry.id))
    let polisher = try await makePolisher(model, options: options)
    await polisher.prepare()
    // The first call pays for whatever prepare() could not warm.
    _ = await polisher.polish("Warm up.")

    var rates: [String: [Double]] = [:]
    var exact = 0
    var times: [Double] = []
    for item in cases {
        let processed = pipeline.run(item.input)
        let report = await polisher.polish(processed)
        let output = report.text ?? processed
        times.append(report.elapsed.timeInterval)
        rates[item.lang, default: []].append(WordErrorRate.compute(reference: item.expected, hypothesis: output))
        let matched = output.trimmingCharacters(in: .whitespacesAndNewlines) == item.expected
        if matched { exact += 1 }
        let failure = report.failure.map { " (\($0))" } ?? ""
        print(String(format: "%@ %-26@ %5.2f s%@", matched ? "=" : " ", item.id, report.elapsed.timeInterval, failure))
        print("    \(output.replacingOccurrences(of: "\n", with: "⏎"))")
    }
    print("")
    let all = rates.values.flatMap { $0 }
    let mean = { (values: [Double]) in values.reduce(0, +) / Double(max(values.count, 1)) }
    let perLanguage = rates.keys.sorted().map { String(format: "%@ %.3f", $0, mean(rates[$0]!)) }.joined(separator: "  ")
    times.sort()
    print(String(format: "WER %.3f (%@), exact %d of %d, polish median %.2f s, p90 %.2f s",
                 mean(all), perLanguage, exact, cases.count, times[times.count / 2], times[Int(Double(times.count) * 0.9)]))
}
