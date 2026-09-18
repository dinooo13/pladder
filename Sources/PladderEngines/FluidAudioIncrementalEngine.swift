import FluidAudio
import Foundation
import PladderCore

/// The batch engine's own windows, run while the user is still speaking.
///
/// `FluidAudioEngine` lays a recording out in ~15 s windows at release and
/// decodes them all then, so a long dictation waits for several encoder
/// passes. Those windows do not depend on each other — each starts from a
/// fresh decoder state, and a window's start is chosen from audio that ends
/// before the previous window does — so every window but the last can run
/// while the recording is still going. `IncrementalChunkProcessor` in the
/// FluidAudio fork does exactly that; at release only the final window and
/// the merge remain, which is one pass at any length.
///
/// The text is the batch engine's text, not an approximation of it: the same
/// windows, in the same order, through the same merge. Below 15 s there are no
/// windows to merge, and `IncrementalChunkProcessor.finish()` hands the buffer
/// to the same call `FluidAudioEngine` makes, so the two agree there too. That
/// short path lives in the fork rather than here: a single window over short
/// audio decodes differently from the whole-buffer pass, so the identity has
/// to hold inside the processor, not around it.
public actor FluidAudioIncrementalEngine: StreamingTranscriptionEngine {
    public static let engineID = EngineID("parakeet-tdt-v3-incremental")

    public nonisolated let id = FluidAudioIncrementalEngine.engineID
    public nonisolated let displayName = "Parakeet TDT v3 (incremental)"
    public private(set) var status: EngineStatus = .unloaded

    private let version: AsrModelVersion
    /// One resident manager, exactly as `FluidAudioEngine` holds: the
    /// incremental processor borrows it window by window and the warm pass
    /// and `transcribe` use it directly.
    private var manager: AsrManager?
    private var session: IncrementalChunkProcessor?
    /// Samples fed this utterance, for the transcript's audio duration only.
    private var fedSampleCount = 0
    /// The samples themselves, kept only so `livePass` has something to
    /// transcribe; the session holds its own copy for the real windows. At the
    /// coordinator's 120 s cap this is 7.7 MB, and it is dropped the moment
    /// the utterance ends, one way or the other.
    private var liveAudio: [Float] = []
    private var loadTask: Task<Void, Error>?

    public init(version: AsrModelVersion = .v3) {
        self.version = version
    }

    public func load() async throws {
        if status.isReady { return }
        if let loadTask { return try await loadTask.value }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        status = .downloading(progress: nil)
        do {
            // The progress handler is invoked off-actor; hop back to update status.
            let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                guard let self else { return }
                Task { await self.report(progress) }
            }
            status = .loading
            // Same configuration as the batch engine, so the two produce the
            // same text: seam-gap repair off (Step 7).
            let manager = AsrManager(config: ASRConfig(seamGapRepair: false))
            try await manager.loadModels(models)
            self.manager = manager
            status = .ready
        } catch {
            status = .failed(message: Self.describe(error))
            throw error
        }
    }

    private func report(_ progress: DownloadProgress) {
        guard case .downloading = status else { return }
        switch progress.phase {
        case .compiling:
            status = .loading
        case .listing, .downloading:
            status = .downloading(progress: progress.fractionCompleted)
        }
    }

    // MARK: StreamingTranscriptionEngine

    public func beginUtterance() async throws {
        guard let manager, status.isReady else { throw EngineError.notLoaded }
        await session?.cancel()
        fedSampleCount = 0
        liveAudio.removeAll(keepingCapacity: true)
        session = try await IncrementalChunkProcessor(manager: manager)
    }

    public func feed(_ samples: [Float]) async {
        guard !samples.isEmpty, let session else { return }
        fedSampleCount += samples.count
        liveAudio.append(contentsOf: samples)
        // A window failing mid-recording must not take the dictation down:
        // `finish()` still runs the last window and merges what did succeed,
        // and it reports the failure itself if it cannot.
        try? await session.append(samples)
    }

    /// Feeds the tail and returns the transcript for the whole utterance.
    /// The timed part is `finish()` alone: the final window plus the merge,
    /// which is all that is left on the release-to-paste path.
    public func endUtterance(_ tail: [Float]) async throws -> Transcript {
        guard status.isReady else { throw EngineError.notLoaded }
        guard let session else { throw EngineError.notLoaded }
        if !tail.isEmpty {
            fedSampleCount += tail.count
            try await session.append(tail)
        }
        let started = ContinuousClock.now
        let result = try await session.finish()
        let elapsed = ContinuousClock.now - started
        self.session = nil
        liveAudio.removeAll(keepingCapacity: true)
        return Transcript(
            text: result.text,
            audioDuration: Double(fedSampleCount) / CapturedAudio.sampleRate,
            processingTime: Self.seconds(elapsed),
            engineID: id
        )
    }

    public func abandonUtterance() async {
        let session = self.session
        self.session = nil
        fedSampleCount = 0
        liveAudio.removeAll(keepingCapacity: true)
        await session?.cancel()
    }

    public func warmPass() async {
        guard let manager, status.isReady else { return }
        // The same encoder pass the last window will make: every utterance is
        // padded to the model's fixed window, so half a second of silence
        // costs what the real call costs and brings the Neural Engine up while
        // the user is still speaking.
        _ = try? await Self.transcribeWholeBuffer(Self.warmupSamples, using: manager)
    }

    /// The warm pass with the real audio in it.
    ///
    /// The window is padded to the model's fixed size either way, so a pass
    /// over what has been said so far costs what the pass over half a second
    /// of silence costs; this warms the Neural Engine exactly as `warmPass`
    /// does and returns text as well. Nothing here touches the session: the
    /// windows the release will merge are untouched by it, which the paced
    /// benchmark's identity gate checks with `--live`.
    ///
    /// Before anything has been fed there is nothing to transcribe, so the
    /// first pass of a recording is the plain warm pass; the key-down warm-up
    /// is not lost by going live.
    public func livePass() async -> String? {
        guard let manager, status.isReady else { return nil }
        let window = liveWindow()
        guard !window.isEmpty else {
            await warmPass()
            return nil
        }
        guard let result = try? await Self.transcribeWholeBuffer(window, using: manager) else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The tail of the recording that fits the model's window, cut on a fixed
    /// grid. A window wider than the model's is decoded in pieces, which
    /// costs more than one pass and is not what a live view is worth; cutting
    /// on a 5 s grid instead of at "the last 15 s" keeps the left edge still
    /// between passes, so the text a reader is following does not shift under
    /// them four times a second.
    private func liveWindow() -> [Float] {
        guard liveAudio.count > Self.maxWindowSamples else { return liveAudio }
        let overflow = liveAudio.count - Self.maxWindowSamples
        let start = ((overflow + Self.windowHopSamples - 1) / Self.windowHopSamples) * Self.windowHopSamples
        return Array(liveAudio[start...])
    }

    // MARK: TranscriptionEngine

    /// One padded pass over the whole buffer, so the CLI and tests can call a
    /// single method. This is the batch path, not the incremental one; the
    /// incremental path needs audio delivered over time to show anything.
    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        guard let manager, status.isReady else { throw EngineError.notLoaded }
        let result = try await Self.transcribeWholeBuffer(samples, using: manager)
        return Transcript(
            text: result.text,
            audioDuration: Double(samples.count) / CapturedAudio.sampleRate,
            processingTime: result.processingTime,
            engineID: id
        )
    }

    public func unload() async {
        await abandonUtterance()
        await manager?.cleanup()
        manager = nil
        status = .unloaded
    }

    private static func transcribeWholeBuffer(
        _ samples: [Float],
        using manager: AsrManager
    ) async throws -> ASRResult {
        // FluidAudio rejects audio shorter than 0.3 s. Pad with silence rather
        // than fail; the coordinator already drops accidental taps.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(CapturedAudio.sampleRate))
        let padded = samples.count < minimum
            ? samples + [Float](repeating: 0, count: minimum - samples.count)
            : samples
        // A fresh decoder state per utterance: each dictation is independent.
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(padded, decoderState: &state)
    }

    /// Half a second of silence for the warm pass. Matches the coordinator's
    /// warm-up so both paths pay for the same encoder pass.
    private static let warmupSamples = [Float](repeating: 0, count: 8_000)

    /// The model's encoder window, 15 s at 16 kHz, taken from FluidAudio so
    /// the two cannot drift. Audio longer than this is decoded in several
    /// passes, which a live view has no business paying for, so it transcribes
    /// the tail that fits.
    private static let maxWindowSamples = ASRConstants.maxModelSamples
    /// The grid the live window's left edge moves on, 5 s: long enough that
    /// the window still holds 10 s of context at its narrowest.
    private static let windowHopSamples = 80_000

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    public enum EngineError: LocalizedError {
        case notLoaded
        public var errorDescription: String? {
            switch self {
            case .notLoaded: return "Speech model is not loaded yet."
            }
        }
    }
}
