import FluidAudio
import Foundation
import PladderCore

// FluidAudio's ~15 s windows do not depend on each other, so all but the last run
// while the user speaks, and the text is the batch path's: the same windows, order and
// merge. See docs/ARCHITECTURE.md, "Engine".
public actor FluidAudioIncrementalEngine: StreamingTranscriptionEngine {
    public static let engineID = EngineID("parakeet-tdt-v3-incremental")

    public nonisolated let id = FluidAudioIncrementalEngine.engineID
    public nonisolated var displayName: String { StandardEngines.parakeet.displayName }
    public private(set) var status: EngineStatus = .unloaded

    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var session: IncrementalChunkProcessor?
    private var fedSampleCount = 0
    // Kept only for `livePass`; the session holds its own copy. 38 MB at the 10 min cap,
    // dropped when the utterance ends.
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
            await resumePartialDownload()
            let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                guard let self else { return }
                Task { await self.report(progress) }
            }
            status = .loading
            // Seam-gap repair off: its probe for words dropped at window seams costs time at
            // release. The session's merge and `transcribe` both read it from this manager.
            let manager = AsrManager(config: ASRConfig(seamGapRepair: false))
            try await manager.loadModels(models)
            self.manager = manager
            status = .ready
        } catch {
            status = .failed(Self.describe(error))
            throw error
        }
    }

    // A kill during the last small files can leave the cache looking whole with one
    // `weight.bin.partial` in it; the load then fails and FluidAudio deletes and refetches
    // the whole ~460 MB repo. `ModelHub.download` resumes just the partial instead.
    private func resumePartialDownload() async {
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
        guard Self.hasPartialDownload(under: cacheDirectory) else { return }
        do {
            try await ModelHub.download(
                Self.repository(for: version),
                to: cacheDirectory.deletingLastPathComponent(),
                variant: Self.encoderVariant(for: version),
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.report(progress) }
                }
            )
        } catch {
            // Fail open: the download below meets the same problem and reports it.
        }
    }

    // `FileDownloader` moves `<file>.partial` into place only after its size check.
    private static func hasPartialDownload(under directory: URL) -> Bool {
        guard
            let walk = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return false }
        for case let url as URL in walk where url.pathExtension == "partial" {
            return true
        }
        return false
    }

    // `AsrModelVersion.repo` makes the same mapping but is not public.
    private static func repository(for version: AsrModelVersion) -> Repo {
        switch version {
        case .v2: return .parakeetV2
        case .v3: return .parakeetV3
        case .tdtCtc110m: return .parakeetTdtCtc110m
        case .tdtJa: return .parakeetJa
        }
    }

    // `AsrModels.download` passes the encoder precision as the variant for v3 only,
    // `.int8` by default; asking for anything else would fetch a second encoder.
    private static func encoderVariant(for version: AsrModelVersion) -> String? {
        switch version {
        case .v3: return ParakeetEncoderPrecision.int8.rawValue
        case .v2, .tdtCtc110m, .tdtJa: return nil
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
        guard let manager, status.isReady else { throw TranscriptionError.notLoaded }
        await session?.cancel()
        fedSampleCount = 0
        liveAudio.removeAll(keepingCapacity: true)
        session = try await IncrementalChunkProcessor(manager: manager)
    }

    public func feed(_ samples: [Float]) async {
        guard !samples.isEmpty, let session else { return }
        fedSampleCount += samples.count
        liveAudio.append(contentsOf: samples)
        // A window failing mid-recording must not take the dictation down: `finish()` still
        // runs the last window and merges what succeeded.
        try? await session.append(samples)
    }

    // Times `finish()` alone, the last window and the merge: all that is left at release.
    public func endUtterance(_ tail: [Float]) async throws -> Transcript {
        guard status.isReady else { throw TranscriptionError.notLoaded }
        guard let session else { throw TranscriptionError.notLoaded }
        // The actor is reentrant across the awaits below, so a `beginUtterance` may already
        // have installed the next session; that one is left be.
        defer {
            if self.session === session {
                self.session = nil
                liveAudio.removeAll(keepingCapacity: true)
            }
        }
        fedSampleCount += tail.count
        let sampleCount = fedSampleCount
        if !tail.isEmpty {
            try await session.append(tail)
        }
        let started = ContinuousClock.now
        let result = try await session.finish()
        let elapsed = ContinuousClock.now - started
        return Transcript(
            text: result.text,
            audioDuration: Double(sampleCount) / CapturedAudio.sampleRate,
            processingTime: elapsed.timeInterval,
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
        _ = try? await Self.transcribeWholeBuffer(Self.warmupSamples, using: manager)
    }

    // Never touches the session, so the windows the release merges are unchanged, which
    // `bench --paced --live` checks. With nothing fed yet it is the plain warm pass.
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

    // A window wider than the model's is decoded in pieces. A 5 s grid keeps the left
    // edge still between passes, so the text does not shift under the reader.
    private func liveWindow() -> [Float] {
        guard liveAudio.count > Self.maxWindowSamples else { return liveAudio }
        let overflow = liveAudio.count - Self.maxWindowSamples
        let start = ((overflow + Self.windowHopSamples - 1) / Self.windowHopSamples) * Self.windowHopSamples
        return Array(liveAudio[start...])
    }

    // MARK: TranscriptionEngine

    // The batch path: one padded pass over the whole buffer, for the CLI and the tests.
    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        guard let manager, status.isReady else { throw TranscriptionError.notLoaded }
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
        // FluidAudio rejects audio shorter than 0.3 s.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(CapturedAudio.sampleRate))
        let padded = samples.count < minimum
            ? samples + [Float](repeating: 0, count: minimum - samples.count)
            : samples
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(padded, decoderState: &state)
    }

    private static let warmupSamples = [Float](repeating: 0, count: 8_000)
    private static let maxWindowSamples = ASRConstants.maxModelSamples
    // Leaves at least 10 s of context in the live window.
    private static let windowHopSamples = 80_000

    private static func describe(_ error: Error) -> EngineFailure {
        switch error {
        case let error as DownloadError:
            return describe(error)
        case let error as AsrModelsError:
            return describe(error)
        case let error as URLError:
            return .download(reason(for: error))
        default:
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return .loadFailed(detail: cut(detail))
        }
    }

    private static func describe(_ error: DownloadError) -> EngineFailure {
        switch error {
        case .invalidResponse, .htmlErrorResponse:
            return .download(.serverError)
        case .rateLimited:
            return .download(.rateLimited)
        case .stalled:
            return .download(.stalled)
        case .downloadFailed(_, let underlying):
            return .download((underlying as? URLError).map(reason(for:)) ?? .network)
        case .invalidArtifact:
            return .download(.damagedFile)
        case .modelNotFound, .modelMissing, .networkDisabled:
            return .incompleteFiles
        }
    }

    private static func describe(_ error: AsrModelsError) -> EngineFailure {
        switch error {
        case .downloadFailed(let reason):
            return .download(.other(detail: cut(reason)))
        case .modelNotFound:
            return .incompleteFiles
        case .loadingFailed(let reason), .modelCompilationFailed(let reason):
            return .loadFailed(detail: cut(reason))
        }
    }

    private static func reason(for error: URLError) -> DownloadFailure {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff:
            return .noConnection
        case .timedOut:
            return .timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return .tls
        case .cancelled:
            return .cancelled
        default:
            return .network
        }
    }

    // Shown verbatim after a translated prefix, so kept to a line.
    private static func cut(_ detail: String) -> String {
        detail.count > 160 ? String(detail.prefix(160)) + "…" : detail
    }
}
