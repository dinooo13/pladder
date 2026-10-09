import Foundation
import PladderBench
import PladderCore
import PladderEngines
import PladderRefine
import PladderSystem

extension PolishModel {
    // No `default`, so a new case does not compile until it has a name here.
    var cliName: String {
        switch self {
        case .appleIntelligence: "apple"
        case .s1Mini: "s1-mini"
        case .s1Mini8Bit: "s1-mini-8bit"
        }
    }

    static var cliNames: String {
        allCases.map(\.cliName).joined(separator: "|")
    }

    init?(cliName: String) {
        guard let model = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = model
    }
}

// Cold, then warm: a real press prewarms the session at key-down, before release.
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

    func show(_ label: String, _ report: PolishReport) {
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

struct PolishOptions {
    var instructionsPath: String?
    var gguf: String?
    var control: String?
}

func makePolisher(_ model: PolishModel, options: PolishOptions = PolishOptions()) async throws -> any ReportingRefiner {
    let instructionsPath = options.instructionsPath
    let file: ModelFile
    let location: URL
    if let gguf = options.gguf {
        if instructionsPath != nil { usage() }
        location = URL(fileURLWithPath: gguf)
        file = ModelFile(fileName: location.lastPathComponent, url: location, sha256: "", byteCount: 0)
    } else if let pinned = ModelFile(for: model) {
        if instructionsPath != nil { usage() }
        let files = ModelFiles(directory: ModelFiles.defaultDirectory) { _, status in
            if case .downloading(let fraction) = status {
                eprint(String(format: "\rdownloading %3.0f%%", fraction * 100), terminator: "")
            } else if status == .verifying {
                eprint("\rverifying          ")
            }
        }
        await files.ensure(pinned)
        let status = await files.finished(pinned)
        guard status == .ready else {
            eprint("\(pinned.fileName): \(status)")
            exit(1)
        }
        file = pinned
        location = files.location(of: pinned)
    } else {
        if options.control != nil { usage() }
        guard let instructionsPath else { return TranscriptPolisher() }
        let instructions = try String(contentsOf: URL(fileURLWithPath: instructionsPath), encoding: .utf8)
        print("instructions: \(instructionsPath)")
        return TranscriptPolisher(instructions: instructions)
    }
    print("model: \(options.gguf ?? file.fileName)")
    if let control = options.control { print("control: \(control)") }
    return S1MiniPolisher(file: file, location: location, control: options.control ?? S1MiniPolisher.controlLine)
}

struct PolishCase: Decodable {
    let id: String
    let lang: String
    let input: String
    let expected: String
}

func runPolishSet(_ path: String, model: PolishModel, options: PolishOptions) async throws {
    let cases = try JSONDecoder().decode([PolishCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard !cases.isEmpty else {
        eprint("pladder-cli: \(path): the test set has no cases")
        exit(1)
    }
    // A fresh install's settings: no dictionary, so the set means the same everywhere.
    let pipeline = StandardProcessors.pipeline(for: DictationSettings(engineID: StandardEngines.defaultEntry.id))
    let polisher = try await makePolisher(model, options: options)
    await polisher.prepare()
    // The first call pays for whatever `prepare()` could not warm.
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
