import Foundation
import PladderBench
import PladderCore
import PladderEngines

// MARK: - Fixtures

struct Fixture {
    var name: String
    var samples: [Float]
    var reference: String
    var duration: Double { Double(samples.count) / CapturedAudio.sampleRate }
}

// Shortest first, so the longest fixture, which heats the chip most, runs last.
func loadFixtures(in dir: URL) throws -> [Fixture] {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    var fixtures: [Fixture] = []
    for url in files where url.pathExtension.lowercased() != "txt" && !url.lastPathComponent.hasPrefix(".") {
        let script = url.deletingPathExtension().appendingPathExtension("txt")
        guard let reference = try? String(contentsOf: script, encoding: .utf8) else {
            eprint("skipping \(url.lastPathComponent): no \(script.lastPathComponent)")
            continue
        }
        let samples = try loadSamples(url)
        fixtures.append(Fixture(name: url.deletingPathExtension().lastPathComponent, samples: samples, reference: reference))
    }
    return fixtures.sorted { $0.duration < $1.duration }
}

// MARK: - What both benchmarks share

func checkBenchOptions(runs: Int, pause: Double) {
    guard runs >= 2 else {
        eprint("--runs must be at least 2 (the first run is discarded)")
        exit(2)
    }
    guard pause >= 0 else {
        eprint("--pause must not be negative")
        exit(2)
    }
}

func printBenchHeader(_ title: String, engine: any TranscriptionEngine) {
    let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    print(title)
    print("machine: \(chip), macOS \(os)")
    print("model:   \(engine.id) (\(engine.displayName))")
}

struct ThermalRecord {
    private(set) var throttled = false

    mutating func note(forRun run: Int) -> String {
        let thermal = thermalTag()
        throttled = throttled || !thermal.isEmpty
        return (run == 1 ? " (warm-up, discarded)" : "") + thermal
    }

    func printFooter() {
        print("")
        print(String(format: "load:    %.2f (one-minute average at end)", loadAverage()))
        if throttled {
            print("warning: the chip left its normal thermal state during the run; numbers are not comparable")
        }
    }
}

struct BenchRow {
    var name: String
    var duration: Double
    var time: Double
    var spread: Double
    var wer: Double

    init(_ fixture: Fixture, times: [Double], errors: [Double]) {
        name = fixture.name
        duration = fixture.duration
        time = median(times)
        // The noise floor for this fixture: a difference smaller than this means nothing.
        spread = (times.max()! - times.min()!) / time
        wer = median(errors)
    }
}

func printBenchTable(
    timed: String,
    rows: [(row: BenchRow, extra: String)],
    extraHeader: String = "",
    extraSeparator: String = ""
) {
    print("")
    print("| Fixture | Audio | \(timed) | Spread | Realtime | WER |\(extraHeader)")
    print("|---|---:|---:|---:|---:|---:|\(extraSeparator)")
    for (row, extra) in rows {
        print(String(
            format: "| %@ | %.1f s | %.3f s | %.0f %% | %.0fx | %.1f %% |%@",
            row.name, row.duration, row.time, row.spread * 100, row.duration / row.time, row.wer * 100, extra))
    }
}

// MARK: - Whole buffer

func runBench(dir: String, runs: Int, pause: Double) async throws {
    checkBenchOptions(runs: runs, pause: pause)
    let fixtures = try loadFixtures(in: URL(fileURLWithPath: dir))
    guard !fixtures.isEmpty else {
        eprint("no fixtures in \(dir); run scripts/make-fixtures.sh first")
        exit(1)
    }

    let engine = makeEngine()
    printBenchHeader("Pladder benchmark", engine: engine)
    print("runs:    \(runs) per fixture, first discarded, median reported")
    print(String(format: "pause:   %.0f s idle before every run, as between real dictations", pause))
    print(String(format: "load:    %.2f (one-minute average at start)", loadAverage()))
    print("")

    let loadTime = try await loadEngine(engine)
    print(String(format: "model load (cold): %.2f s", loadTime.timeInterval))
    if let bytes = physicalFootprintBytes() {
        print(String(format: "memory after load: %.0f MB (physical footprint)", Double(bytes) / 1_048_576))
    }
    print("")

    var rows: [(row: BenchRow, extra: String)] = []
    let clock = ContinuousClock()
    var thermal = ThermalRecord()
    for fixture in fixtures {
        var times: [Double] = []
        var errors: [Double] = []
        for run in 1...runs {
            // Every run starts from idle, like a dictation; back to back, runs would hand each
            // other warm clocks and residual heat.
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            let started = clock.now
            let transcript = try await engine.transcribe(fixture.samples)
            let elapsed = (clock.now - started).timeInterval
            let wer = WordErrorRate.compute(reference: fixture.reference, hypothesis: transcript.text)
            let note = thermal.note(forRun: run)
            print(String(format: "%@ run %d: %.3f s, WER %.1f%%%@", fixture.name, run, elapsed, wer * 100, note))
            if run > 1 {
                times.append(elapsed)
                errors.append(wer)
            }
        }
        rows.append((BenchRow(fixture, times: times, errors: errors), ""))
    }

    printBenchTable(timed: "Engine (median)", rows: rows)
    thermal.printFooter()
}

// MARK: - Paced

func firstWordDifference(
    batch: String,
    paced: String
) -> (index: Int, batch: String, paced: String)? {
    let left = batch.split(whereSeparator: \.isWhitespace).map(String.init)
    let right = paced.split(whereSeparator: \.isWhitespace).map(String.init)
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : "<end>"
        let b = index < right.count ? right[index] : "<end>"
        if a != b { return (index, a, b) }
    }
    return nil
}

// Locked: the live task records into it while the run's own task paces the audio.
final class LivePassLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _times: [Double] = []
    var times: [Double] { lock.withLock { _times } }
    func record(_ elapsed: Double) { lock.withLock { _times.append(elapsed) } }
}

// The identity gate: every fixture also goes through the engine whole, and the raw
// texts must match. With `live`, a pass over the audio so far runs every 0.5 s while
// pacing and is cancelled before the release, as the coordinator's feed loop is.
func runPacedBench(dir: String, runs: Int, pause: Double, includeShort: Bool, live: Bool) async throws {
    checkBenchOptions(runs: runs, pause: pause)
    var fixtures = try loadFixtures(in: URL(fileURLWithPath: dir))
    // Below ~13 s both paths run one padded window: nothing paced about the result.
    if !includeShort { fixtures = fixtures.filter { $0.duration >= 13 } }
    guard !fixtures.isEmpty else {
        eprint("no paced fixtures in \(dir)")
        exit(1)
    }

    guard let engine = makeEngine() as? any StreamingTranscriptionEngine else {
        eprint("\(StandardEngines.defaultEntry.id) does not transcribe while speaking; there is nothing to pace")
        exit(1)
    }
    printBenchHeader("Pladder benchmark (paced)", engine: engine)
    print("runs:    \(runs) per fixture, first discarded, median of `endUtterance` reported")
    print(String(format: "pause:   %.0f s idle before every run", pause))
    print("compare: the same engine, whole buffer, once per fixture, raw text")
    if live {
        print("live:    a live pass every 0.5 s while the fixture is paced, as the Live Transcript overlay makes")
    }
    print("")

    let loadTime = try await loadEngine(engine)
    print(String(format: "model load (cold): %.2f s", loadTime.timeInterval))
    print("")

    var rows: [(row: BenchRow, extra: String)] = []
    let clock = ContinuousClock()
    var thermal = ThermalRecord()
    for fixture in fixtures {
        var times: [Double] = []
        var errors: [Double] = []
        var livePassTimes: [Double] = []
        var livePassCounts: [Int] = []
        var lastText = ""
        for run in 1...runs {
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            let utterance = try await engine.beginUtterance()
            let passes = LivePassLog()
            let liveTask: Task<Void, Never>? = live ? Task {
                while !Task.isCancelled {
                    let started = clock.now
                    _ = await engine.livePass(utterance)
                    passes.record((clock.now - started).timeInterval)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            } : nil
            var offset = 0
            let oneSecond = Int(CapturedAudio.sampleRate)
            while offset + oneSecond < fixture.samples.count {
                await engine.feed(Array(fixture.samples[offset..<offset + oneSecond]), to: utterance)
                try await Task.sleep(for: .seconds(1))
                offset += oneSecond
            }
            let tail = Array(fixture.samples[offset...])
            // Cancelled and not awaited, as the release does: a pass already inside CoreML
            // cannot be aborted, so the timed call waits for it, which is part of the style's cost.
            liveTask?.cancel()
            let started = clock.now
            let transcript = try await engine.endUtterance(utterance, tail: tail)
            let elapsed = (clock.now - started).timeInterval
            lastText = transcript.text
            let wer = WordErrorRate.compute(reference: fixture.reference, hypothesis: transcript.text)
            let note = thermal.note(forRun: run)
            let runPasses = passes.times
            let liveNote = live
                ? String(format: ", %d live passes (median %.3f s)", runPasses.count, median(runPasses))
                : ""
            print(String(format: "%@ run %d: %.3f s, WER %.1f%%%@%@", fixture.name, run, elapsed, wer * 100, liveNote, note))
            if run > 1 {
                times.append(elapsed)
                errors.append(wer)
                livePassTimes.append(contentsOf: runPasses)
                livePassCounts.append(runPasses.count)
            }
        }

        // Anything but `identical: yes` is a bug in the incremental path. Timed after the
        // same idle pause: straight after a paced run the Neural Engine would be warm.
        if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        let batchStarted = clock.now
        let batchTranscript = try await engine.transcribe(fixture.samples)
        let batchElapsed = (clock.now - batchStarted).timeInterval
        let batchWer = WordErrorRate.compute(reference: fixture.reference, hypothesis: batchTranscript.text)
        print(String(format: "%@ whole: %.3f s, WER %.1f%%", fixture.name, batchElapsed, batchWer * 100))
        let difference = firstWordDifference(batch: batchTranscript.text, paced: lastText)
        if let difference {
            print("\(fixture.name) identical: no, first differing word \(difference.index): whole \"\(difference.batch)\" vs paced \"\(difference.paced)\"")
        } else {
            print("\(fixture.name) identical: yes")
        }

        let livePasses = Int(median(livePassCounts.map(Double.init)).rounded())
        let liveCells = live ? String(format: " %d | %.3f s |", livePasses, median(livePassTimes)) : ""
        rows.append((
            BenchRow(fixture, times: times, errors: errors),
            " \(difference == nil ? "yes" : "no") |\(liveCells)"))
    }

    printBenchTable(
        timed: "endUtterance (median)",
        rows: rows,
        extraHeader: " Identical whole-buffer |\(live ? " Live passes | Live pass (median) |" : "")",
        extraSeparator: "---|\(live ? "---:|---:|" : "")")
    thermal.printFooter()
}
