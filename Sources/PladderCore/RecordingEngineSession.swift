import Foundation

// See docs/ARCHITECTURE.md, "Dictation flow".
@MainActor
final class RecordingEngineSession {
    struct Intervals: Sendable {
        var feed: Duration
        var livePass: Duration
        var warmup: Duration
    }

    struct Ending: Sendable {
        let source: DictationFinish.Source
        // Awaited at release: a chunk drained just before is still fed, so every sample
        // reaches the engine once and in order.
        let feed: Task<Int, Never>?
        // The feed loop's engine call in flight at the end, which only a cancel stops.
        let handover: Task<Void, Never>?

        // The engine drops the utterance only once the feed has exited, so no chunk lands
        // after it.
        func abandon() async {
            guard case .utterance(let engine, let utterance) = source else { return }
            handover?.cancel()
            _ = await feed?.value
            await engine.abandonUtterance(utterance)
        }
    }

    // Every utterance is padded to the model's full window, so half a second of
    // silence costs the same encoder pass as a real call.
    static let warmupSamples = [Float](repeating: 0, count: 8_000)

    private let engine: any TranscriptionEngine
    private let capture: any AudioCapture
    private let clock: any Clock<Duration>
    private let intervals: Intervals
    private let live: Bool
    private let onPartial: @MainActor (String?) -> Void
    private var streaming: (engine: any StreamingTranscriptionEngine, utterance: Utterance)?
    private var feed: Task<Int, Never>?
    private var handover: Task<Void, Never>?
    // Cancelling cannot abort a CoreML call already started, so a release landing in
    // a warm pass waits for that call, inside `engine-time`.
    private var warmup: Task<Void, Never>?
    private(set) var isEnded = false

    init(
        engine: any TranscriptionEngine,
        capture: any AudioCapture,
        clock: any Clock<Duration>,
        intervals: Intervals,
        live: Bool,
        onPartial: @escaping @MainActor (String?) -> Void
    ) {
        self.engine = engine
        self.capture = capture
        self.clock = clock
        self.intervals = intervals
        self.live = live
        self.onPartial = onPartial
    }

    // A streaming engine that cannot begin an utterance is used like a batch engine:
    // transcribed whole at release, slower but not lost.
    func begin() async {
        guard let engine = engine as? (any StreamingTranscriptionEngine),
              let utterance = try? await engine.beginUtterance()
        else { return }
        guard !isEnded else {
            await engine.abandonUtterance(utterance)
            return
        }
        streaming = (engine, utterance)
    }

    func startLoops() {
        guard !isEnded else { return }
        if let streaming {
            startFeed(streaming.engine, utterance: streaming.utterance)
            // The live loop's pass is the warm pass; a second loop would only compete with it.
            if !live { startWarmupLoop { [engine = streaming.engine] in await engine.warmPass() } }
        } else {
            startWarmupLoop { [engine, warmupSamples = Self.warmupSamples] in
                _ = try? await engine.transcribe(warmupSamples)
            }
        }
    }

    // Synchronous: it only cancels, so the release path waits on nothing here.
    @discardableResult
    func end() -> Ending {
        isEnded = true
        feed?.cancel()
        warmup?.cancel()
        warmup = nil
        let source: DictationFinish.Source = if let streaming {
            .utterance(streaming.engine, streaming.utterance)
        } else {
            .whole(engine)
        }
        return Ending(source: source, feed: feed, handover: handover)
    }

    // One loop for feed and live passes, so they never drain against each other.
    private func startFeed(_ engine: any StreamingTranscriptionEngine, utterance: Utterance) {
        feed = Task { [weak self, capture, clock, intervals, live] in
            var fed = 0
            // Counted down by the feed sleeps, so audio goes in on the feed cadence in every
            // style and a live pass starts `livePass` after the previous one ended.
            var livePassDue: Duration? = live ? .zero : nil
            while !Task.isCancelled {
                if livePassDue.map({ $0 > .zero }) ?? true {
                    try? await clock.sleep(for: intervals.feed)
                    livePassDue = livePassDue.map { $0 - intervals.feed }
                }
                guard let self, !Task.isCancelled, !self.isEnded else { return fed }
                let chunk = await capture.drain()
                if !chunk.isEmpty {
                    fed += chunk.count
                    // Kept from the release's cancel: FluidAudio checks for it between decoder
                    // frames, and a window pass it stops is run again from the start by
                    // `endUtterance`, so the release would wait for the whole pass.
                    let handover = Task { await engine.feed(chunk, to: utterance) }
                    self.handover = handover
                    await handover.value
                    self.handover = nil
                }
                guard let due = livePassDue, due <= .zero, !Task.isCancelled else { continue }
                let text = await engine.livePass(utterance)
                // A pass finishing after the release would put stale text back on screen.
                guard !Task.isCancelled, !self.isEnded else { return fed }
                self.onPartial(text)
                livePassDue = intervals.livePass
            }
            return fed
        }
    }

    private func startWarmupLoop(_ warm: @escaping @Sendable () async -> Void) {
        warmup?.cancel()
        warmup = Task.detached(priority: .utility) { [clock, interval = intervals.warmup] in
            while !Task.isCancelled {
                await warm()
                if Task.isCancelled { return }
                try? await clock.sleep(for: interval)
            }
        }
    }
}
