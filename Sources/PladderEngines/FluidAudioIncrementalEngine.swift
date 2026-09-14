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
        session = try await IncrementalChunkProcessor(manager: manager)
    }

    public func feed(_ samples: [Float]) async {
        guard !samples.isEmpty, let session else { return }
        fedSampleCount += samples.count
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
