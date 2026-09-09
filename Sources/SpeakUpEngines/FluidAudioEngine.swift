import Foundation
import FluidAudio
import SpeakUpCore

/// Parakeet TDT 0.6B via FluidAudio's CoreML port. Runs on the Neural Engine.
///
/// Model files (about 700 MB for v3) are downloaded from Hugging Face on first
/// load into ~/Library/Application Support/FluidAudio/Models and reused after.
public actor FluidAudioEngine: TranscriptionEngine {
    public static let engineID = EngineID("parakeet-tdt-v3")

    public nonisolated let id = FluidAudioEngine.engineID
    public nonisolated let displayName = "Parakeet TDT v3 (FluidAudio)"
    public private(set) var status: EngineStatus = .unloaded

    private let version: AsrModelVersion
    private var manager: AsrManager?
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
            let manager = AsrManager(config: .default)
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

    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        guard let manager, status.isReady else {
            throw EngineError.notLoaded
        }
        // FluidAudio rejects audio shorter than 0.3 s. Pad with silence rather
        // than fail; the coordinator already drops accidental taps.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(CapturedAudio.sampleRate))
        let padded = samples.count < minimum
            ? samples + [Float](repeating: 0, count: minimum - samples.count)
            : samples

        // A fresh decoder state per utterance: each dictation is independent.
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state)
        return Transcript(
            text: result.text,
            audioDuration: Double(samples.count) / CapturedAudio.sampleRate,
            processingTime: result.processingTime,
            engineID: id
        )
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        status = .unloaded
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
