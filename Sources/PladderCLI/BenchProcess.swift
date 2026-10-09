import Foundation
import PladderCore
import PladderEngines
import PladderSystem

// What the processor pipeline costs: "Processors" in docs/BENCHMARKS.md.
enum ProcessorBench {
    static func run(arguments: [String]) {
        var runs = 31
        var directory: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--runs" {
                guard let value = rest.popFirst(), let count = Int(value) else { usage() }
                runs = count
            } else if directory == nil {
                directory = argument
            } else {
                usage()
            }
        }
        guard let directory else { usage() }
        guard runs >= 2 else {
            eprint("--runs must be at least 2 (the first run is discarded)")
            exit(2)
        }
        run(directory: directory, runs: runs)
    }

    static func run(directory: String, runs: Int) {
        let fixtures = loadScripts(in: directory)
        guard !fixtures.isEmpty else {
            eprint("no fixture scripts in \(directory); run scripts/make-fixtures.sh first")
            exit(1)
        }
        let settings = DictationSettings(engineID: FluidAudioIncrementalEngine.engineID)
        let pipeline = StandardProcessors.pipeline(for: settings)

        print("Pladder processor benchmark")
        print("runs:    \(runs) per variant, first discarded, median reported")
        print("typical: \"um,\" after the first word of every sentence")
        print("worst:   typical, and \"question mark\" at the end of every sentence")
        print("")
        print("| Fixture | Words | Typical (median) | Worst (median) |")
        print("|---|---:|---:|---:|")
        let clock = ContinuousClock()
        for (name, script) in fixtures {
            let sentences = Self.sentences(in: script)
            var medians: [Double] = []
            for variant in [typical(sentences), worst(sentences)] {
                var times: [Double] = []
                for attempt in 1...runs {
                    let started = clock.now
                    _ = pipeline.run(variant)
                    let elapsed = clock.now - started
                    if attempt > 1 { times.append(elapsed / .milliseconds(1)) }
                }
                medians.append(median(times))
            }
            let words = script.split(whereSeparator: \.isWhitespace).count
            print(String(format: "| %@ | %d | %.2f ms | %.2f ms |", name, words, medians[0], medians[1]))
        }
    }

    private static func loadScripts(in directory: String) -> [(name: String, script: String)] {
        let url = URL(fileURLWithPath: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            eprint("cannot read \(directory)")
            exit(1)
        }
        let scripts = files
            .filter { $0.pathExtension.lowercased() == "txt" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { file -> (name: String, script: String)? in
                guard let script = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return (file.deletingPathExtension().lastPathComponent, script)
            }
        return scripts.sorted { $0.script.count < $1.script.count }
    }

    // The fixtures hold one sentence per line; the engine writes one line.
    static func sentences(in script: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in script {
            current.append(character.isNewline ? " " : character)
            if ".!?".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences.filter { !$0.isEmpty }
    }

    static func typical(_ sentences: [String]) -> String {
        sentences.map { sentence in
            var words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            words.insert("um,", at: min(1, words.count))
            return words.joined(separator: " ")
        }.joined(separator: " ")
    }

    static func worst(_ sentences: [String]) -> String {
        typical(sentences.map { sentence in
            guard let last = sentence.last, ".!?".contains(last) else { return sentence + " question mark" }
            return String(sentence.dropLast()) + " question mark" + String(last)
        })
    }
}
