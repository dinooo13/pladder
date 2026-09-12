@preconcurrency import AVFoundation
import Darwin
import Foundation
import PladderAudio
import PladderBench
import PladderCore
import PladderEngines

// Developer tool.
//
//   pladder-cli <audio file>              load Parakeet, print the transcript and timing
//   pladder-cli bench <fixtures dir>      run the benchmark (see docs/BENCHMARKS.md)
//       [--runs N]                        runs per fixture, default 6; the first is discarded.
//                                         Use 11 to settle a result near the noise line.
//       [--pause S]                       idle seconds before every run, default 10
//
// Fixtures are audio files with a sibling .txt holding the spoken script, as
// produced by scripts/make-fixtures.sh.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: pladder-cli <audio file>
           pladder-cli bench <fixtures dir> [--runs N] [--pause S]

    """.utf8))
    exit(2)
}

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"]) }
    try file.read(into: input)
    let target = try AudioResampler.monoFloat32Format()
    return try AudioResampler.convert(input, to: target)
}

/// Loads the engine, printing download progress, and returns the wall-clock
/// load time. In a fresh process this is the cold start the app pays at launch.
func loadEngine(_ engine: FluidAudioEngine) async throws -> Duration {
    let clock = ContinuousClock()
    let started = clock.now
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
    defer { statusTask.cancel() }
    try await engine.load()
    return clock.now - started
}

func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

/// Physical memory footprint of this process, the number Activity Monitor
/// shows in its Memory column.
func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

/// One-minute load average, so the conditions of a run are on the record.
func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
}

/// Empty when the chip is at its normal thermal state, else a tag for the
/// run line, because a throttled run is not comparable.
func thermalTag() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return ""
    case .fair: return " [thermal: fair]"
    case .serious: return " [thermal: serious]"
    case .critical: return " [thermal: critical]"
    @unknown default: return " [thermal: unknown]"
    }
}

// MARK: - Transcribe one file

func transcribeFile(_ path: String) async throws {
    let engine = FluidAudioEngine()
    let loadTime = try await loadEngine(engine)
    print(String(format: "model ready in %.1fs", seconds(loadTime)))

    let samples = try loadSamples(URL(fileURLWithPath: path))
    let transcript = try await engine.transcribe(samples)
    print(String(format: "audio %.2fs, processed in %.3fs (%.0fx realtime)", transcript.audioDuration, transcript.processingTime, transcript.realtimeFactor))
    print("TEXT: \(transcript.text)")
}

// MARK: - Benchmark

struct Fixture {
    var name: String
    var samples: [Float]
    var reference: String
    var duration: Double { Double(samples.count) / CapturedAudio.sampleRate }
}

/// Every audio file in `dir` that has a sibling `.txt`, shortest first so the
/// longest fixture, which heats the chip the most, runs last.
func loadFixtures(in dir: URL) throws -> [Fixture] {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    var fixtures: [Fixture] = []
    for url in files where url.pathExtension.lowercased() != "txt" && !url.lastPathComponent.hasPrefix(".") {
        let script = url.deletingPathExtension().appendingPathExtension("txt")
        guard let reference = try? String(contentsOf: script, encoding: .utf8) else {
            FileHandle.standardError.write(Data("skipping \(url.lastPathComponent): no \(script.lastPathComponent)\n".utf8))
            continue
        }
        let samples = try loadSamples(url)
        fixtures.append(Fixture(name: url.deletingPathExtension().lastPathComponent, samples: samples, reference: reference))
    }
    return fixtures.sorted { $0.duration < $1.duration }
}

func runBench(dir: String, runs: Int, pause: Double) async throws {
    guard runs >= 2 else {
        FileHandle.standardError.write(Data("--runs must be at least 2 (the first run is discarded)\n".utf8))
        exit(2)
    }
    guard pause >= 0 else {
        FileHandle.standardError.write(Data("--pause must not be negative\n".utf8))
        exit(2)
    }
    let fixtures = try loadFixtures(in: URL(fileURLWithPath: dir))
    guard !fixtures.isEmpty else {
        FileHandle.standardError.write(Data("no fixtures in \(dir); run scripts/make-fixtures.sh first\n".utf8))
        exit(1)
    }

    let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let engine = FluidAudioEngine()
    print("Pladder benchmark")
    print("machine: \(chip), macOS \(os)")
    print("model:   \(engine.id) (\(engine.displayName))")
    print("runs:    \(runs) per fixture, first discarded, median reported")
    print(String(format: "pause:   %.0f s idle before every run, as between real dictations", pause))
    print(String(format: "load:    %.2f (one-minute average at start)", loadAverage()))
    print("")

    let loadTime = try await loadEngine(engine)
    print(String(format: "model load (cold): %.2f s", seconds(loadTime)))
    if let bytes = physicalFootprintBytes() {
        print(String(format: "memory after load: %.0f MB (physical footprint)", Double(bytes) / 1_048_576))
    }
    print("")

    struct Row { var name: String; var duration: Double; var engine: Double; var spread: Double; var wer: Double }
    var rows: [Row] = []
    let clock = ContinuousClock()
    var throttled = false
    for fixture in fixtures {
        var times: [Double] = []
        var errors: [Double] = []
        for run in 1...runs {
            // Every run starts from idle, like a dictation does. Back-to-back
            // runs would hand each other warm clocks and residual heat.
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            let started = clock.now
            let transcript = try await engine.transcribe(fixture.samples)
            let elapsed = seconds(clock.now - started)
            let wer = WordErrorRate.compute(reference: fixture.reference, hypothesis: transcript.text)
            let thermal = thermalTag()
            throttled = throttled || !thermal.isEmpty
            let note = (run == 1 ? " (warm-up, discarded)" : "") + thermal
            print(String(format: "%@ run %d: %.3f s, WER %.1f%%%@", fixture.name, run, elapsed, wer * 100, note))
            if run > 1 {
                times.append(elapsed)
                errors.append(wer)
            }
        }
        let engineTime = median(times)
        // Spread of the kept runs relative to the median: the noise floor
        // for this fixture, so a difference smaller than it means nothing.
        let spread = (times.max()! - times.min()!) / engineTime
        rows.append(Row(name: fixture.name, duration: fixture.duration, engine: engineTime, spread: spread, wer: median(errors)))
    }

    print("")
    print("| Fixture | Audio | Engine (median) | Spread | Realtime | WER |")
    print("|---|---:|---:|---:|---:|---:|")
    for row in rows {
        print(String(
            format: "| %@ | %.1f s | %.3f s | %.0f %% | %.0fx | %.1f %% |",
            row.name, row.duration, row.engine, row.spread * 100, row.duration / row.engine, row.wer * 100))
    }
    print("")
    print(String(format: "load:    %.2f (one-minute average at end)", loadAverage()))
    if throttled {
        print("warning: the chip left its normal thermal state during the run; numbers are not comparable")
    }
}

// MARK: - Entry

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil, "-h", "--help":
    usage()
case "bench":
    arguments.removeFirst()
    var runs = 6
    var pause = 10.0
    var dir: String?
    while let arg = arguments.first {
        arguments.removeFirst()
        if arg == "--runs" {
            guard let value = arguments.first, let n = Int(value) else { usage() }
            arguments.removeFirst()
            runs = n
        } else if arg == "--pause" {
            guard let value = arguments.first, let s = Double(value) else { usage() }
            arguments.removeFirst()
            pause = s
        } else if dir == nil {
            dir = arg
        } else {
            usage()
        }
    }
    guard let dir else { usage() }
    try await runBench(dir: dir, runs: runs, pause: pause)
case let path?:
    try await transcribeFile(path)
}
