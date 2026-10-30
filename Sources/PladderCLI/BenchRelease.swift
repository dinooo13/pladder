import Foundation
import PladderCore
import PladderSystem

// What a release waits for, by where it lands: "The release wait" in
// docs/BENCHMARKS.md. The real coordinator and engine, a fixture played in at real
// time, and a release at chosen instants of the recording.
enum ReleaseBench {
    struct Options {
        var fixture: String?
        var at: [Double] = []
        var uniform: (from: Double, to: Double, count: Int)?
        var runs = 3
        var pause: Duration = .seconds(3)
        var feedInterval: Duration?
    }

    static func run(arguments: [String]) async throws {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--at":
                guard let value = rest.popFirst() else { usage() }
                options.at = value.split(separator: ",").map { Double($0) ?? -1 }
                guard options.at.allSatisfy({ $0 >= 0.3 }) else { usage() }
            case "--uniform":
                // from-to:count, e.g. 2-30:40
                guard let value = rest.popFirst() else { usage() }
                let parts = value.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Double($0) }
                guard parts.count == 3, parts[0] >= 0.3, parts[1] > parts[0], parts[2] >= 1 else { usage() }
                options.uniform = (parts[0], parts[1], Int(parts[2]))
            case "--runs":
                guard let value = rest.popFirst(), let count = Int(value), count >= 1 else { usage() }
                options.runs = count
            case "--pause":
                guard let value = rest.popFirst(), let seconds = Double(value), seconds >= 0 else { usage() }
                options.pause = .milliseconds(Int(seconds * 1_000))
            case "--feed-interval":
                guard let value = rest.popFirst(), let ms = Int(value), ms > 0 else { usage() }
                options.feedInterval = .milliseconds(ms)
            default:
                guard options.fixture == nil else { usage() }
                options.fixture = argument
            }
        }
        guard let fixture = options.fixture, !options.at.isEmpty || options.uniform != nil else { usage() }
        try await run(options, fixture: fixture)
    }

    // Spread evenly with a fixed jitter, so every build gets the same release times.
    static func releaseTimes(_ options: Options) -> [Double] {
        var times = options.at
        if let uniform = options.uniform {
            var generator = SplitMix(seed: 84)
            let step = (uniform.to - uniform.from) / Double(uniform.count)
            for index in 0..<uniform.count {
                times.append(uniform.from + step * (Double(index) + Double.random(in: 0..<1, using: &generator)))
            }
        }
        return times
    }

    struct Run {
        var at: Double
        var total: Duration
        var feed: Duration
        var stop: Duration
        var engine: Duration
        var engineTime: Duration
        var busy: String
        var passes: String
        var waited: Duration { feed + engine - engineTime }
    }

    @MainActor
    static func run(_ options: Options, fixture path: String) async throws {
        let samples = try loadSamples(URL(fileURLWithPath: path))
        guard let inner = makeEngine() as? any StreamingTranscriptionEngine else {
            eprint("\(selectedEngine.id) does not transcribe while speaking; nothing is waited for at release")
            exit(1)
        }
        let trace = EngineTrace()
        let engine = TracingEngine(inner: inner, trace: trace)
        let capture = FixtureCapture(samples: samples)
        let stamps = EventStamps()
        let coordinator = DictationCoordinator(
            settings: DictationSettings(engineID: engine.id),
            registry: EngineRegistry([.init(id: engine.id, displayName: engine.displayName, detail: "") { engine }]),
            capture: capture,
            output: TimedOutput(latency: .zero),
            refiner: nil,
            hotkeyMonitor: SilentHotkeyMonitor(),
            makePipeline: { StandardProcessors.pipeline(for: $0) },
            onEvent: { stamps.stamp($0) }
        )
        if let feedInterval = options.feedInterval { coordinator.feedInterval = feedInterval }
        coordinator.start()
        while !coordinator.engineStatus.isReady || coordinator.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let times = releaseTimes(options)
        printBenchHeader("Pladder release-wait benchmark", engine: inner)
        print(String(format: "load:    %.2f (1-minute average) at start", loadAverage()))
        print(String(format: "fixture: %@, %.1f s, silence after its end", (path as NSString).lastPathComponent,
            Double(samples.count) / CapturedAudio.sampleRate))
        print("runs:    \(options.runs) rounds over \(times.count) release times, \(format(options.pause)) idle before each")
        print("feed:    every \(format(coordinator.feedInterval))")
        print("waited:  feed + engine - engine-time; busy: what was running at the release")
        print("")

        // One discarded run pays CoreML's first call.
        _ = try await dictate(coordinator, capture: capture, trace: trace, stamps: stamps, at: 3, pause: options.pause)
        var runs: [Run] = []
        for round in 1...options.runs {
            for at in times {
                let run = try await dictate(
                    coordinator, capture: capture, trace: trace, stamps: stamps, at: at, pause: options.pause)
                runs.append(run)
                print(String(format: "round %d at %6.2f s: total %@, feed %@, stop %@, engine %@, engine-time %@, waited %@%@",
                    round, at, format(run.total), format(run.feed), format(run.stop), format(run.engine),
                    format(run.engineTime), format(run.waited), run.busy.isEmpty ? "" : ", busy: \(run.busy)")
                    + "; \(run.passes)")
            }
        }
        coordinator.stop()

        print("")
        print("| Release at | Runs | Total (median) | Waited (mean / max) | Waited ≥ 20 ms |")
        print("|---:|---:|---:|---:|---:|")
        if !options.at.isEmpty {
            for at in options.at {
                row(String(format: "%.2f s", at), runs.filter { $0.at == at })
            }
        }
        if let uniform = options.uniform {
            let label = String(format: "%.0f–%.0f s, %d spread", uniform.from, uniform.to, uniform.count)
            row(label, runs.filter { !options.at.contains($0.at) })
        }
        print(String(format: "load:    %.2f (1-minute average) at end", loadAverage()))
    }

    private static func row(_ label: String, _ runs: [Run]) {
        guard !runs.isEmpty else { return }
        let waited = runs.map(\.waited)
        let slow = waited.filter { $0 >= .milliseconds(20) }.count
        print("| \(label) | \(runs.count) | \(format(median(runs.map(\.total)))) "
            + "| \(format(waited.reduce(.zero, +) / runs.count)) / \(format(waited.max() ?? .zero)) | \(slow) |")
    }

    @MainActor
    private static func dictate(
        _ coordinator: DictationCoordinator, capture: FixtureCapture, trace: EngineTrace,
        stamps: EventStamps, at: Double, pause: Duration
    ) async throws -> Run {
        try? await Task.sleep(for: pause)
        trace.reset()
        await coordinator.hotkeyPressed()
        guard coordinator.state.isRecording, let started = await capture.startedAt else {
            eprint("the press was refused in state \(coordinator.state)")
            exit(1)
        }
        try? await Task.sleep(until: started + .milliseconds(Int(at * 1_000)), tolerance: .zero, clock: .continuous)
        let released = ContinuousClock.now
        coordinator.hotkeyReleased()
        await coordinator.inFlight?.value
        guard let insertion = stamps.insertion, let stopped = stamps.stopped, let inserted = stamps.inserted else {
            eprint("nothing was inserted at \(at) s (state \(coordinator.state))")
            exit(1)
        }
        stamps.reset()
        let timing = insertion.timing
        return Run(
            at: at, total: inserted - stopped, feed: timing.feed, stop: timing.captureStop, engine: timing.engine,
            engineTime: .seconds(insertion.transcript.processingTime),
            busy: trace.running(at: released),
            passes: trace.passes(since: started))
    }

    private static func median(_ values: [Duration]) -> Duration {
        let sorted = values.sorted()
        return sorted.isEmpty ? .zero : sorted[(sorted.count - 1) / 2]
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.0f ms", duration / .milliseconds(1))
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Stand-ins

// The calls in flight, so a run can say what its release landed in.
private final class EngineTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [(kind: String, start: ContinuousClock.Instant, end: ContinuousClock.Instant?)] = []

    func begin(_ kind: String) -> Int {
        lock.withLock {
            spans.append((kind, .now, nil))
            return spans.count - 1
        }
    }

    func end(_ index: Int) {
        lock.withLock {
            guard index < spans.count else { return }
            spans[index].end = .now
        }
    }

    func reset() {
        lock.withLock { spans.removeAll() }
    }

    // Feeds of 20 ms or more ran a window: when, from the capture's start, and for how long.
    func passes(since started: ContinuousClock.Instant) -> String {
        lock.withLock {
            let first = spans.first { $0.kind == "feed" }.map {
                String(format: "first feed at %.2f s; ", ($0.start - started) / .seconds(1))
            } ?? ""
            return first + spans.compactMap { span -> String? in
                guard span.kind == "feed", let end = span.end, end - span.start >= .milliseconds(20) else { return nil }
                return String(format: "%.2f s for %.0f ms", (span.start - started) / .seconds(1),
                    (end - span.start) / .milliseconds(1))
            }.joined(separator: ", ")
        }
    }

    // A feed that lasted under 5 ms ran no window; it is not worth naming.
    func running(at instant: ContinuousClock.Instant) -> String {
        lock.withLock {
            spans.filter { span in
                guard span.start <= instant else { return false }
                guard let end = span.end else { return true }
                return end > instant && (span.kind != "feed" || end - span.start > .milliseconds(5))
            }.map { span in
                let into = (instant - span.start) / .milliseconds(1)
                let length = span.end.map { String(format: " of %.0f", ($0 - span.start) / .milliseconds(1)) } ?? ""
                return String(format: "%@ %.0f%@ ms in", span.kind, into, length)
            }.joined(separator: " + ")
        }
    }
}

private actor TracingEngine: StreamingTranscriptionEngine {
    let inner: any StreamingTranscriptionEngine
    let trace: EngineTrace
    nonisolated let id: EngineID
    nonisolated let displayName: String

    init(inner: any StreamingTranscriptionEngine, trace: EngineTrace) {
        self.inner = inner
        self.trace = trace
        self.id = inner.id
        self.displayName = inner.displayName
    }

    private(set) var status: EngineStatus = .unloaded

    // Read once the load ends: the bench expects the model already downloaded.
    func load() async throws {
        do {
            try await inner.load()
        } catch {
            status = await inner.status
            throw error
        }
        status = await inner.status
    }

    func unload() async {
        await inner.unload()
        status = .unloaded
    }
    func transcribe(_ samples: [Float]) async throws -> Transcript { try await inner.transcribe(samples) }
    func beginUtterance() async throws -> Utterance { try await inner.beginUtterance() }
    func abandonUtterance(_ utterance: Utterance) async { await inner.abandonUtterance(utterance) }

    func feed(_ samples: [Float], to utterance: Utterance) async {
        let span = trace.begin("feed")
        await inner.feed(samples, to: utterance)
        trace.end(span)
    }

    func endUtterance(_ utterance: Utterance, tail: [Float]) async throws -> Transcript {
        try await inner.endUtterance(utterance, tail: tail)
    }

    func warmPass() async {
        let span = trace.begin("warm")
        await inner.warmPass()
        trace.end(span)
    }

    func livePass(_ utterance: Utterance) async -> String? {
        let span = trace.begin("live")
        defer { trace.end(span) }
        return await inner.livePass(utterance)
    }
}

// The fixture at the real rate from `start`, then silence: a drain or a stop returns
// what a microphone would have captured since the last one.
private actor FixtureCapture: AudioCapture {
    private let samples: [Float]
    private(set) var startedAt: ContinuousClock.Instant?
    private var handedOut = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() async throws -> AsyncStream<Float> {
        startedAt = .now
        handedOut = 0
        return AsyncStream { _ in }
    }

    func drain() async -> [Float] {
        collect()
    }

    func stop() async -> CapturedAudio {
        let tail = collect()
        startedAt = nil
        return CapturedAudio(samples: tail)
    }

    func warmUp() async throws {}

    private func collect() -> [Float] {
        guard let startedAt else { return [] }
        let due = Int((ContinuousClock.now - startedAt).timeInterval * CapturedAudio.sampleRate)
        guard due > handedOut else { return [] }
        let real = handedOut < samples.count ? Array(samples[handedOut..<min(due, samples.count)]) : []
        let chunk = real + [Float](repeating: 0, count: due - handedOut - real.count)
        handedOut = due
        return chunk
    }
}
