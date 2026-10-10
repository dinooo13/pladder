import FluidAudio
import Foundation
import PladderCore

/// FluidAudio's batch windows, run while the user is still speaking.
///
/// FluidAudio's batch path, `AsrManager.transcribe`, lays a recording out in
/// ~15 s windows and decodes them all in one call, so a long dictation
/// transcribed at release would wait for several encoder passes. Those
/// windows do not depend on each other — each starts from a fresh decoder
/// state, and a window's start is chosen from audio that ends before the
/// previous window does — so every window but the last can run while the
/// recording is still going. `IncrementalChunkProcessor` in the FluidAudio
/// fork does exactly that; at release only the final window and the merge
/// remain, which is one pass at any length.
///
/// The text is the batch path's text, not an approximation of it: the same
/// windows, in the same order, through the same merge. Below 15 s there are no
/// windows to merge, and `IncrementalChunkProcessor.finish()` makes the same
/// single padded pass over the buffer that `transcribe(_:)` makes, so the two
/// agree there too. That short path lives in the fork rather than here: a
/// single window over short audio decodes differently from the whole-buffer
/// pass, so the identity has to hold inside the processor, not around it.
public actor FluidAudioIncrementalEngine: StreamingTranscriptionEngine {
    public static let engineID = EngineID("parakeet-tdt-v3-incremental")

    public nonisolated let id = FluidAudioIncrementalEngine.engineID
    /// The catalog's name, so the picker and the CLI's bench header agree.
    public nonisolated var displayName: String { StandardEngines.parakeet.displayName }
    public private(set) var status: EngineStatus = .unloaded

    private let version: AsrModelVersion
    /// One resident manager: the incremental processor borrows it window by
    /// window, and the warm pass, the live pass and `transcribe` use it
    /// directly.
    private var manager: AsrManager?
    /// The utterance in progress and its windows, from `beginUtterance`
    /// until it ends or is abandoned. Calls naming any other utterance are
    /// stale and change nothing.
    private var slot = UtteranceSlot<IncrementalChunkProcessor>()
    /// Samples fed this utterance, for the transcript's audio duration only.
    private var fedSampleCount = 0
    /// The samples themselves, kept only so `livePass` has something to
    /// transcribe; the session holds its own copy for the real windows. At the
    /// coordinator's 10 min cap this is 38 MB, and it is dropped the moment
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
            await resumePartialDownload()
            // The progress handler is invoked off-actor; hop back to update status.
            let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                guard let self else { return }
                Task { await self.report(progress) }
            }
            status = .loading
            // Seam-gap repair off: FluidAudio's post-merge probe for words
            // dropped at window seams runs on every recording longer than one
            // window and costs time at release. The session's merge and
            // `transcribe` both read the setting from this manager, so the
            // two paths stay identical.
            let manager = AsrManager(config: ASRConfig(seamGapRepair: false))
            try await manager.loadModels(models)
            self.manager = manager
            status = .ready
        } catch {
            status = .failed(Self.describe(error))
            throw error
        }
    }

    /// Finishes a half-written model cache before the loader decides it is
    /// complete.
    ///
    /// FluidAudio resumes an interrupted file: it streams into
    /// `<file>.partial` with an ETag validator beside it and a new process
    /// continues it with a `Range` request, and it refuses any body whose
    /// size differs from the one Hugging Face listed, so a truncated file is
    /// never moved into place. What it does not do is notice a partial once
    /// the cache *looks* whole: `AsrModels.download` skips the fetch when
    /// every model directory and the vocabulary exist
    /// (`AsrModels.modelsExist`), which a kill during the last few small
    /// files can leave true while one bundle still holds only a
    /// `weights/weight.bin.partial`. The load then fails on that bundle and
    /// FluidAudio's recovery deletes the whole ~460 MB repo and fetches it
    /// again.
    ///
    /// `ModelHub.download` is the layer below that decision: it skips files
    /// already in place and resumes the partial, so running it first turns
    /// the purge into the few megabytes that were actually missing. When
    /// there is no partial — every launch after the first — this is one
    /// `FileManager` walk of a ten-entry tree. It runs at launch, nowhere
    /// near the release-to-paste path.
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
            // Fail open. Whatever stopped the resume stops the download below
            // as well, and that one reports the failure to the menu; a
            // pre-pass that throws on its own would only replace a resumable
            // state with an error message.
        }
    }

    /// Whether any file under the cache is still being downloaded.
    /// `FileDownloader` writes `<file>.partial` and moves it into place only
    /// after the size check, so a `.partial` anywhere means an interrupted
    /// run, whatever the directory listing suggests.
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

    /// The same mapping `AsrModelVersion.repo` makes inside FluidAudio, which
    /// is not public; `Repo` and its cases are.
    private static func repository(for version: AsrModelVersion) -> Repo {
        switch version {
        case .v2: return .parakeetV2
        case .v3: return .parakeetV3
        case .tdtCtc110m: return .parakeetTdtCtc110m
        case .tdtJa: return .parakeetJa
        }
    }

    /// `AsrModels.download` passes the encoder precision as the repo variant
    /// for v3 only, and its default precision is `.int8`; the pre-pass has to
    /// ask for the same files or it would fetch a second encoder.
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

    public func beginUtterance() async throws -> Utterance {
        guard let manager, status.isReady else { throw TranscriptionError.notLoaded }
        // Claimed before the awaits below: the actor is reentrant across
        // them, and a second `beginUtterance` or an abandon of this one may
        // arrive in the meantime.
        let (utterance, replaced) = slot.begin()
        fedSampleCount = 0
        liveAudio.removeAll(keepingCapacity: true)
        await replaced?.cancel()
        let session: IncrementalChunkProcessor
        do {
            session = try await IncrementalChunkProcessor(manager: manager)
        } catch {
            slot.release(utterance)
            throw error
        }
        guard slot.install(session, for: utterance) else {
            await session.cancel()
            throw CancellationError()
        }
        return utterance
    }

    public func feed(_ samples: [Float], to utterance: Utterance) async {
        guard !samples.isEmpty, let session = slot.session(for: utterance) else { return }
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
    public func endUtterance(_ utterance: Utterance, tail: [Float]) async throws -> Transcript {
        guard status.isReady else { throw TranscriptionError.notLoaded }
        guard let session = slot.session(for: utterance) else { throw TranscriptionError.notLoaded }
        // The utterance is over whether `finish()` returns or throws. The
        // actor is reentrant across the awaits below, so a `beginUtterance`
        // may already have claimed the slot for the next one; that one is
        // left be.
        defer {
            if slot.release(utterance).wasCurrent { liveAudio.removeAll(keepingCapacity: true) }
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

    public func abandonUtterance(_ utterance: Utterance) async {
        let (wasCurrent, session) = slot.release(utterance)
        guard wasCurrent else { return }
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
    public func livePass(_ utterance: Utterance) async -> String? {
        guard let manager, status.isReady, slot.current == utterance else { return nil }
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
        if let current = slot.current { await abandonUtterance(current) }
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

    /// What the menu says under `Model failed:` when the load throws.
    ///
    /// The distinction worth a user's attention is whether the network or the
    /// files are at fault: a download that stopped continues from where it
    /// stopped when they choose Retry, missing or damaged files are fetched
    /// again, and only what is left is an engine problem. The raw
    /// `errorDescription` said none of that — a lost connection during the
    /// first-launch download read as an engine bug, which is what the issue
    /// was opened about.
    ///
    /// A value, not a sentence: the app owns the wording and the catalog.
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

    /// The engine's own free text is shown verbatim after a translated
    /// prefix, so it is kept to a line.
    private static func cut(_ detail: String) -> String {
        detail.count > 160 ? String(detail.prefix(160)) + "…" : detail
    }
}
