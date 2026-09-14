import AVFoundation
import FluidAudio
import Foundation
import PladderCore

/// Parakeet TDT 0.6B streamed through FluidAudio's sliding-window manager:
/// audio is transcribed in ~11 s windows while it is being recorded, so that
/// at release only the tail after the last confirmed chunk remains to
/// transcribe.
///
/// Reuses the same downloaded models as `FluidAudioEngine`; there is no
/// second download. Registered as a second entry so the batch engine stays
/// the default and reverting is one registry line.
public actor FluidAudioStreamingEngine: StreamingTranscriptionEngine {
    public static let engineID = EngineID("parakeet-tdt-v3-streaming")

    public nonisolated let id = FluidAudioStreamingEngine.engineID
    public nonisolated let displayName = "Parakeet TDT v3 (streaming)"
    public private(set) var status: EngineStatus = .unloaded

    private let version: AsrModelVersion
    private var models: AsrModels?
    /// Resident batch manager for the hybrid short-utterance path: warm the
    /// model exactly as `FluidAudioEngine` does, so an utterance below one
    /// chunk can be decoded as a full batch pass instead of the degraded
    /// streaming flush. Costs nothing extra at load; `loadModels` holds
    /// references to the shared CoreML models only.
    private var batchManager: AsrManager?
    /// A fresh manager per utterance: `finish()` and `cancel()` permanently
    /// foreclose the manager's input stream, so it cannot be reused. Building
    /// one is cheap; `loadModels` only stores references to the shared model.
    private var session: SlidingWindowAsrManager?
    /// Everything fed plus the tail for the current utterance, so the
    /// hybrid path can transcribe the complete recording when the
    /// streaming feed never confirmed a chunk. Reserves 10 s up front, like
    /// the capture side.
    private var utteranceSamples: [Float] = [Float](repeating: 0, count: 0)
    private var loadTask: Task<Void, Error>?

    /// Below the batch engine's own single-window size (15 s padded input),
    /// the sliding window has confirmed at most one chunk, and batch decodes
    /// the complete recording in one padded pass at batch speed and quality:
    /// streaming still has nothing confirmed worth flushing. This is where
    /// the hybrid path takes over.
    private static let shortUtteranceSamples = ASRConstants.maxModelSamples

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
            let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                guard let self else { return }
                Task { await self.report(progress) }
            }
            status = .loading
            self.models = models
            // Resident short-utterance path; matches `FluidAudioEngine`'s
            // configuration (seam-gap repair off, which short audio never
            // reaches anyway).
            let batchManager = AsrManager(config: ASRConfig(seamGapRepair: false))
            try await batchManager.loadModels(models)
            self.batchManager = batchManager
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
        guard let models, status.isReady else { throw EngineError.notLoaded }
        utteranceSamples.removeAll(keepingCapacity: true)
        let session = SlidingWindowAsrManager(config: .default)
        try await session.loadModels(models)
        try await session.startStreaming(source: .microphone)
        self.session = session
    }

    public func feed(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        utteranceSamples.append(contentsOf: samples)
        guard let buffer = Self.pcmBuffer(from: samples) else { return }
        await session?.streamAudio(buffer)
    }

    /// Feeds the tail and returns the transcript for the whole utterance.
    public func endUtterance(_ tail: [Float]) async throws -> Transcript {
        guard status.isReady else { throw EngineError.notLoaded }
        utteranceSamples.append(contentsOf: tail)

        // Hybrid: below one chunk + right context the sliding window has
        // confirmed nothing, so decode the complete recording the way the
        // batch engine does — one padded pass, the full buffer with right
        // context implied by the model's fixed window.
        if utteranceSamples.count < Self.shortUtteranceSamples {
            await abandonUtterance()
            return try await transcribeAsBatch(utteranceSamples, audioDuration: Double(utteranceSamples.count) / CapturedAudio.sampleRate)
        }

        guard let session else { throw EngineError.notLoaded }
        if !tail.isEmpty, let buffer = Self.pcmBuffer(from: tail) {
            await session.streamAudio(buffer)
        }
        // Give the last real chunk its right context, the same zeros-padding
        // the batch engine does over the whole utterance. Without it,
        // FluidAudio flushes the tail as a window with no right context,
        // which is where the trailing words of a dictation go missing.
        //
        // The padding is minimal, not a fixed 13 s nor "complete the next
        // full window": the flush loop runs exactly one window when the
        // leftover after the last confirmed centre equals one chunk, so pad
        // to exactly that. The flush window then spans the remaining speech
        // plus `chunk - remainder` zeros at its end — real right context
        // inside the window, one pass. Padding `chunk + right` would let the
        // regular loop swallow the padded window and leave a second, all-zero
        // window for the flush: two passes, ~70 ms, for the same words.
        let chunk = Self.chunkSamples
        let right = Self.rightContextSamples
        let total = utteranceSamples.count
        let lastCentre = max(0, total - right) / chunk * chunk
        let remainder = max(0, total - lastCentre)
        let zeros = max(0, chunk - remainder)
        if let buffer = Self.pcmBuffer(from: [Float](repeating: 0, count: zeros)) {
            await session.streamAudio(buffer)
        }
        let started = ContinuousClock.now
        let text = try await session.finish()
        let elapsed = ContinuousClock.now - started
        self.session = nil
        let parts = elapsed.components
        return Transcript(
            text: text,
            audioDuration: 0,
            processingTime: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            engineID: id
        )
    }

    /// One padded full-buffer pass through the resident batch manager, i.e.
    /// exactly what `FluidAudioEngine.transcribe` does.
    private func transcribeAsBatch(_ samples: [Float], audioDuration: Double) async throws -> Transcript {
        guard let batchManager else { throw EngineError.notLoaded }
        // FluidAudio rejects audio shorter than 0.3 s; pad with silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(CapturedAudio.sampleRate))
        let padded = samples.count < minimum
            ? samples + [Float](repeating: 0, count: minimum - samples.count)
            : samples
        var state = try TdtDecoderState(decoderLayers: await batchManager.decoderLayerCount)
        let started = ContinuousClock.now
        let result = try await batchManager.transcribe(padded, decoderState: &state)
        let elapsed = ContinuousClock.now - started
        let parts = elapsed.components
        return Transcript(
            text: result.text,
            audioDuration: audioDuration,
            processingTime: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            engineID: id
        )
    }

    public func abandonUtterance() async {
        let session = self.session
        self.session = nil
        await session?.cancel()
    }

    public func warmPass() async {
        // One batch pass of silence: the sliding windows stay idle until the
        // first 13 s chunk completes, so the Neural Engine warms up through
        // the resident batch manager instead. Same encoder pass the real
        // call makes, spent while the user is still speaking.
        _ = try? await transcribeAsBatch(Self.warmupSamples, audioDuration: 0)
    }

    // MARK: TranscriptionEngine

    /// Begin, feed, end, so the CLI and tests can still call one method.
    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        try await beginUtterance()
        await feed(samples)
        var transcript = try await endUtterance([])
        transcript.audioDuration = Double(samples.count) / CapturedAudio.sampleRate
        return transcript
    }

    public func unload() async {
        await abandonUtterance()
        await batchManager?.cleanup()
        batchManager = nil
        models = nil
        status = .unloaded
    }

    /// Chunk and right context of `.default` in samples, for exact tail
    /// padding math.
    private static let chunkSamples = Int(SlidingWindowAsrConfig.default.chunkSeconds * 16_000)
    private static let rightContextSamples = Int(SlidingWindowAsrConfig.default.rightContextSeconds * 16_000)

    /// Half a second of silence for the warm pass. Matches the coordinator's
    /// warm-up so both paths pay for the same encoder pass.
    private static let warmupSamples = [Float](repeating: 0, count: 8_000)

    /// 16 kHz mono buffer, the format `SlidingWindowAsrManager` converts from.
    private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        return buffer
    }

    public enum EngineError: LocalizedError {
        case notLoaded
        public var errorDescription: String? {
            switch self {
            case .notLoaded: return "Speech model is not loaded yet."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}

