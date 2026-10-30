import Foundation
import PladderCore
import PladderSystem

// The coordinator's own share of release-to-paste: "The coordinator's share" in
// docs/BENCHMARKS.md. Stand-ins of fixed latency for everything the coordinator
// drives, so what is left of the total is the coordinator.
enum CoordinatorBench {
    struct Options {
        var runs = 21
        var hold: Duration = .milliseconds(1_500)
        var engineLatency: Duration = .milliseconds(150)
        var pasteLatency: Duration = .zero
        var polish = false
        var live = false
    }

    static let polishLatency: Duration = .milliseconds(300)

    static func run(arguments: [String]) async {
        var options = Options()
        var rest = arguments[...]
        func number(_ value: String?) -> Double {
            guard let value, let number = Double(value), number >= 0 else { usage() }
            return number
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--runs":
                guard let value = rest.popFirst(), let count = Int(value) else { usage() }
                options.runs = count
            case "--hold": options.hold = .milliseconds(Int(number(rest.popFirst()) * 1_000))
            case "--engine-latency": options.engineLatency = .milliseconds(Int(number(rest.popFirst())))
            case "--paste-latency": options.pasteLatency = .milliseconds(Int(number(rest.popFirst())))
            case "--polish": options.polish = true
            case "--live": options.live = true
            default: usage()
            }
        }
        guard options.runs >= 2 else {
            eprint("--runs must be at least 2 (the first run is discarded)")
            exit(2)
        }
        guard options.hold >= .milliseconds(300) else {
            eprint("--hold must be at least 0.3 s, the coordinator's minimum recording")
            exit(2)
        }
        await run(options)
    }

    struct Run {
        var total: Duration
        var share: Duration
        var engineExcess: Duration
    }

    @MainActor
    static func run(_ options: Options) async {
        let engine = FixedLatencyEngine(latency: options.engineLatency)
        let stamps = EventStamps()
        var settings = DictationSettings(engineID: FixedLatencyEngine.engineID)
        settings.polishDictations = options.polish
        settings.liveTranscript = options.live
        let coordinator = DictationCoordinator(
            settings: settings,
            registry: EngineRegistry([
                .init(id: engine.id, displayName: engine.displayName, detail: "") { engine },
            ]),
            capture: SilentCapture(),
            output: TimedOutput(latency: options.pasteLatency),
            refiner: options.polish ? FixedLatencyRefiner(latency: polishLatency) : nil,
            hotkeyMonitor: SilentHotkeyMonitor(),
            makePipeline: { StandardProcessors.pipeline(for: $0) },
            onEvent: { stamps.stamp($0) }
        )
        coordinator.start()
        while !coordinator.engineStatus.isReady || coordinator.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }

        var overshoots: [Duration] = []
        for _ in 0..<11 {
            let started = ContinuousClock.now
            await uncancellableSleep(options.engineLatency)
            overshoots.append(ContinuousClock.now - started - options.engineLatency)
        }

        printBenchHeader("Pladder coordinator benchmark", engine: engine)
        print(String(format: "load:    %.2f (1-minute average) at start", loadAverage()))
        print("runs:    \(options.runs), first discarded, median reported")
        print("hold:    \(format(options.hold)), engine \(format(options.engineLatency)), "
            + "paste \(format(options.pasteLatency))"
            + (options.polish ? ", polish \(format(polishLatency))" : "")
            + (options.live ? ", Live Transcript" : ""))
        print("timer:   a \(format(options.engineLatency)) stand-in sleep overshoots by \(format(median(overshoots))) "
            + "(median), which engine excess includes")
        print("")

        var kept: [Run] = []
        for attempt in 1...options.runs {
            await coordinator.hotkeyPressed()
            guard coordinator.state.isRecording else {
                eprint("run \(attempt): the press was refused in state \(coordinator.state)")
                exit(1)
            }
            try? await Task.sleep(for: options.hold)
            coordinator.hotkeyReleased()
            await coordinator.inFlight?.value
            guard let insertion = stamps.insertion, let stopped = stamps.stopped, let inserted = stamps.inserted else {
                eprint("run \(attempt): nothing was inserted (state \(coordinator.state))")
                exit(1)
            }
            stamps.reset()
            let timing = insertion.timing
            let total = inserted - stopped
            let stages = timing.feed + timing.captureStop + timing.engine + timing.processing + timing.insert
                + (timing.polish ?? .zero)
            let run = Run(
                total: total, share: total - stages,
                engineExcess: timing.feed + timing.engine - options.engineLatency)
            let tag = attempt == 1 ? " (discarded)" : ""
            print("run \(attempt): total \(format(run.total)) (feed \(format(timing.feed)), "
                + "stop \(format(timing.captureStop)), "
                + "process \(format(timing.processing))), share \(format(run.share)), "
                + "engine excess \(format(run.engineExcess))\(tag)")
            if attempt > 1 { kept.append(run) }
            // Lets the release's detached work (the clipboard prepare, the mute restore) end.
            try? await Task.sleep(for: .milliseconds(100))
        }
        coordinator.stop()

        let shares = kept.map(\.share)
        print("")
        print("| Hold | Engine | Total (median) | Share (median / p90 / max) | Engine excess (median) |")
        print("|---:|---:|---:|---:|---:|")
        print("| \(format(options.hold)) | \(format(options.engineLatency)) "
            + "| \(format(median(kept.map(\.total)))) "
            + "| \(format(median(shares))) / \(format(percentile(shares, 0.9))) / \(format(shares.max() ?? .zero)) "
            + "| \(format(median(kept.map(\.engineExcess)))) |")
        print(String(format: "load:    %.2f (1-minute average) at end", loadAverage()))
    }

    private static func median(_ values: [Duration]) -> Duration {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Duration], _ fraction: Double) -> Duration {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .zero }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    private static func format(_ duration: Duration) -> String {
        let ms = duration / .milliseconds(1)
        return ms.magnitude >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.2f ms", ms)
    }
}

// MARK: - Stand-ins

private final class EventStamps: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped: ContinuousClock.Instant?
    private var _inserted: ContinuousClock.Instant?
    private var _insertion: DictationCoordinator.Insertion?
    var stopped: ContinuousClock.Instant? { lock.withLock { _stopped } }
    var inserted: ContinuousClock.Instant? { lock.withLock { _inserted } }
    var insertion: DictationCoordinator.Insertion? { lock.withLock { _insertion } }

    func stamp(_ event: DictationCoordinator.Event) {
        let now = ContinuousClock.now
        lock.withLock {
            switch event {
            case .recordingStopped: _stopped = now
            case .inserted(let insertion):
                _inserted = now
                _insertion = insertion
            default: break
            }
        }
    }

    func reset() {
        lock.withLock {
            _stopped = nil
            _inserted = nil
            _insertion = nil
        }
    }
}

// Ignores cancellation, as a CoreML pass in flight does. A strict timer: `Task.sleep`
// overshoots 150 ms by about 8 ms on an M1 even with zero tolerance, this by 0.2 ms.
private func uncancellableSleep(_ duration: Duration) async {
    guard duration > .zero else { return }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + duration.timeInterval, leeway: .nanoseconds(0))
        timer.setEventHandler {
            timer.cancel()
            done.resume()
        }
        timer.resume()
    }
}

private actor FixedLatencyEngine: StreamingTranscriptionEngine {
    static let engineID = EngineID("fixed-latency")
    nonisolated let id = FixedLatencyEngine.engineID
    nonisolated let displayName = "Fixed latency (benchmark)"
    private(set) var status: EngineStatus = .unloaded
    private let latency: Duration
    private var slot = UtteranceSlot<Void>()

    // About what a dictation of this length looks like, with a filler for the processors.
    private static let text = "So um I think we should move the review to Thursday afternoon and send the notes to the whole team before then."

    init(latency: Duration) {
        self.latency = latency
    }

    func load() async throws { status = .ready }
    func unload() async { status = .unloaded }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        await uncancellableSleep(latency)
        return transcript(samples: samples.count)
    }

    func beginUtterance() async throws -> Utterance {
        let (utterance, _) = slot.begin()
        _ = slot.install((), for: utterance)
        return utterance
    }

    func feed(_ samples: [Float], to utterance: Utterance) async {}

    func endUtterance(_ utterance: Utterance, tail: [Float]) async throws -> Transcript {
        guard slot.release(utterance).wasCurrent else { throw TranscriptionError.notLoaded }
        await uncancellableSleep(latency)
        return transcript(samples: 0)
    }

    func abandonUtterance(_ utterance: Utterance) async {
        slot.release(utterance)
    }

    func warmPass() async {
        await uncancellableSleep(latency)
    }

    func livePass(_ utterance: Utterance) async -> String? {
        guard slot.session(for: utterance) != nil else { return nil }
        await uncancellableSleep(latency)
        return Self.text
    }

    // An audio duration of zero lets the coordinator fill in what it fed.
    private func transcript(samples: Int) -> Transcript {
        Transcript(
            text: Self.text,
            audioDuration: Double(samples) / CapturedAudio.sampleRate,
            processingTime: latency.timeInterval,
            engineID: id
        )
    }
}

// Silence at the real rate: a drain or a stop returns what a microphone would have
// captured since the last one.
private actor SilentCapture: AudioCapture {
    private var since: ContinuousClock.Instant?

    func start() async throws -> AsyncStream<Float> {
        since = .now
        return AsyncStream { _ in }
    }

    func drain() async -> [Float] {
        collect()
    }

    func stop() async -> CapturedAudio {
        let samples = collect()
        since = nil
        return CapturedAudio(samples: samples)
    }

    func warmUp() async throws {}

    private func collect() -> [Float] {
        guard let since else { return [] }
        let now = ContinuousClock.now
        self.since = now
        let count = Int((now - since).timeInterval * CapturedAudio.sampleRate)
        return [Float](repeating: 0, count: count)
    }
}

private struct TimedOutput: TextOutput {
    let latency: Duration

    func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        await uncancellableSleep(latency)
        return .pasted
    }

    func copy(_ text: String) async {}
}

private struct FixedLatencyRefiner: TranscriptRefiner {
    let latency: Duration

    func prepare() async {}

    func refine(_ text: String) async -> String? {
        await uncancellableSleep(latency)
        return text
    }
}

private struct SilentHotkeyMonitor: HotkeyMonitor {
    func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        AsyncStream { _ in }
    }

    func stop() {}
    func setCancelKeyEnabled(_ enabled: Bool) {}
}
