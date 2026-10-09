import Foundation
import PladderCore
import PladderEngines
import PladderSystem

/// `pladder-cli bench-process <fixtures dir> [--runs N]`: what the processor
/// pipeline costs on the fixtures' text (see "Processors" in
/// docs/BENCHMARKS.md).
///
/// Every fixture's `.txt`, the script `scripts/make-fixtures.sh` wrote beside
/// its audio, is read as one line of transcript and run through the pipeline
/// `--process` runs, built from a fresh install's settings, in two variants:
/// "typical" has the filler "um," after the first word of every sentence,
/// "worst" also says "question mark" at the end of every sentence. Each
/// variant runs `runs` times; the first is discarded and the median of the
/// rest reported.
///
/// Self-contained on purpose: nothing else in this tool is used here, so the
/// file and its one `case` in main.swift can be copied onto an older commit
/// to measure a change before and after.
enum ProcessorBench {
    /// Parses what follows `bench-process` on the command line and runs it.
    static func run(arguments: [String]) async {
        var runs = 31
        var directory: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--runs" {
                guard let value = rest.popFirst(), let count = Int(value) else { usageError() }
                runs = count
            } else if directory == nil {
                directory = argument
            } else {
                usageError()
            }
        }
        guard let directory else { usageError() }
        guard runs >= 2 else { fail("--runs must be at least 2 (the first run is discarded)", status: 2) }
        await run(directory: directory, runs: runs)
    }

    static func run(directory: String, runs: Int) async {
        let fixtures = loadScripts(in: directory)
        guard !fixtures.isEmpty else {
            fail("no fixture scripts in \(directory); run scripts/make-fixtures.sh first", status: 1)
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
                    // `await` whether or not `run` is async, so this file
                    // builds against either.
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

    /// Every `.txt` in `directory` with its name, shortest first.
    private static func loadScripts(in directory: String) -> [(name: String, script: String)] {
        let url = URL(fileURLWithPath: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            fail("cannot read \(directory)", status: 1)
        }
        let scripts = files
            .filter { $0.pathExtension.lowercased() == "txt" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { file -> (name: String, script: String)? in
                guard let script = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return (file.deletingPathExtension().lastPathComponent, script)
            }
        return scripts.sorted { $0.script.count < $1.script.count }
    }

    /// The script's sentences, each with its closing mark, line breaks read
    /// as spaces: the fixtures hold one sentence per line, and the engine
    /// writes one line.
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

    /// "um," after the first word of every sentence.
    static func typical(_ sentences: [String]) -> String {
        sentences.map { sentence in
            var words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            words.insert("um,", at: min(1, words.count))
            return words.joined(separator: " ")
        }.joined(separator: " ")
    }

    /// The typical variant with "question mark" spoken before every
    /// sentence's closing mark.
    static func worst(_ sentences: [String]) -> String {
        typical(sentences.map { sentence in
            guard let last = sentence.last, ".!?".contains(last) else { return sentence + " question mark" }
            return String(sentence.dropLast()) + " question mark" + String(last)
        })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func usageError() -> Never {
        fail("usage: pladder-cli bench-process <fixtures dir> [--runs N]", status: 2)
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
