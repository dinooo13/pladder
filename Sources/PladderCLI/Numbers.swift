import Foundation
import PladderBench
import PladderCore
import PladderEngines
import PladderSystem

// How often the engine leaves numbers as words: "Number words" in docs/BENCHMARKS.md.
enum NumberWordsBench {
    struct Case: Decodable {
        let id: String
        let lang: String
        let kind: String
        let spoken: String
        let expected: String
        let also: [String]?

        var targets: [String] { [expected] + (also ?? []) }
    }

    // For a case whose expected text has no digits ("prose"), `words` is the right answer.
    enum Outcome: String, CaseIterable {
        case words, digits, mixed, wrong

        var tag: String {
            switch self {
            case .words: "W"
            case .digits: "D"
            case .mixed: "M"
            case .wrong: "X"
            }
        }
    }

    struct Tally {
        var counts: [Outcome: Int] = [:]
        var exact = 0
        var total: Int { counts.values.reduce(0, +) }
    }

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2 else { usage() }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let directory = URL(fileURLWithPath: arguments[1])
        let voiceDirectories = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        // A fresh install's settings, as for polish-set: no dictionary, so the set means the same everywhere.
        let pipeline = StandardProcessors.pipeline(for: DictationSettings(engineID: selectedEngine.id))

        let engine = makeEngine()
        _ = try await loadEngine(engine)
        print("engine:  \(selectedEngine.id.rawValue)")
        print(String(format: "load:    %.2f at start", loadAverage()))
        print("")

        var raw: [String: Tally] = [:]
        var processed: [String: Tally] = [:]
        var files = 0
        for item in cases {
            for voice in voiceDirectories where voice.hasPrefix(item.lang + "-") {
                let file = directory.appending(path: voice).appending(path: item.id + ".wav")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                files += 1
                let text = try await engine.transcribe(loadSamples(file)).text
                let cleaned = pipeline.run(text)
                let outcome = classify(text, item)
                let after = classify(cleaned, item)
                let key = item.lang + " " + item.kind
                raw[key, default: Tally()].counts[outcome, default: 0] += 1
                processed[key, default: Tally()].counts[after, default: 0] += 1
                if isExact(text, item) { raw[key]!.exact += 1 }
                if isExact(cleaned, item) { processed[key]!.exact += 1 }
                print("\(outcome.tag) \(item.id) \(voice): \(text)")
                if cleaned != text { print("  \(after.tag) processed: \(cleaned)") }
            }
        }
        guard files > 0 else {
            eprint("no audio in \(directory.path); run scripts/make-number-fixtures.sh first")
            exit(1)
        }

        let order = cases.reduce(into: [String]()) { keys, item in
            let key = item.lang + " " + item.kind
            if !keys.contains(key) { keys.append(key) }
        }
        print("")
        printTable("engine output", raw, order: order)
        print("")
        printTable("after the processors", processed, order: order)
        print("")
        print(String(format: "load:    %.2f at end; %d files", loadAverage(), files))
    }

    static func classify(_ output: String, _ item: Case) -> Outcome {
        let written = digits(of: output)
        let wanted = Set(item.targets.map(digits(of:)))
        if wanted.contains("") { return written.isEmpty ? .words : .digits }
        if wanted.contains(written) { return .digits }
        // The words the expected text replaced with digits, symbols or units.
        var numberWords = WordErrorRate.normalize(item.spoken)
        for token in WordErrorRate.normalize(item.expected) {
            if let index = numberWords.firstIndex(of: token) { numberWords.remove(at: index) }
        }
        let heard = Set(WordErrorRate.normalize(output))
        let left = numberWords.contains(where: heard.contains)
        if written.isEmpty { return left ? .words : .wrong }
        return left ? .mixed : .wrong
    }

    static func isExact(_ output: String, _ item: Case) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.targets.contains(trimmed)
    }

    static func digits(of text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    static func printTable(_ title: String, _ tallies: [String: Tally], order: [String]) {
        print("\(title): share of clips per outcome; exact = the expected text to the character")
        print("| Language | Kind | Clips | Words | Digits | Mixed | Wrong | Exact |")
        print("|---|---|---|---|---|---|---|---|")
        let percent = { (count: Int, total: Int) in String(format: "%.0f %%", 100 * Double(count) / Double(max(total, 1))) }
        func row(_ language: String, _ kind: String, _ tally: Tally) {
            let shares = Outcome.allCases.map { percent(tally.counts[$0, default: 0], tally.total) }
            print("| \(language) | \(kind) | \(tally.total) | \(shares.joined(separator: " | ")) | \(tally.exact) |")
        }
        var language = ""
        var numbers = Tally()
        func flush() {
            guard !language.isEmpty else { return }
            row(language, "**all but prose**", numbers)
            numbers = Tally()
        }
        for key in order {
            guard let tally = tallies[key] else { continue }
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            if parts[0] != language { flush(); language = parts[0] }
            row(parts[0], parts[1], tally)
            if parts[1] != "prose" {
                for (outcome, count) in tally.counts { numbers.counts[outcome, default: 0] += count }
                numbers.exact += tally.exact
            }
        }
        flush()
    }
}
