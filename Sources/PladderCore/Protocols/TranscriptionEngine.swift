import Foundation

/// A speech-to-text backend. Implementations are actors so the coordinator can
/// call them from the main actor without blocking UI.
///
/// Adding an engine: implement this protocol in its own module and register a
/// factory in `EngineRegistry`. Nothing else in the app needs to change.
public protocol TranscriptionEngine: Actor {
    /// Stable identifier, also used as the settings key.
    nonisolated var id: EngineID { get }

    /// Human readable name for the settings picker.
    nonisolated var displayName: String { get }

    /// Current readiness. The coordinator disables the hotkey until `.ready`.
    var status: EngineStatus { get }

    /// Download (if needed) and load the model into memory. Safe to call more
    /// than once; subsequent calls return immediately when already loaded.
    func load() async throws

    /// Transcribe 16 kHz mono Float32 PCM samples in [-1, 1].
    func transcribe(_ samples: [Float]) async throws -> Transcript

    /// Release the model from memory.
    func unload() async
}

public struct EngineID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum EngineStatus: Equatable, Sendable {
    case unloaded
    /// `progress` is 0...1 when known, nil when indeterminate.
    case downloading(progress: Double?)
    case loading
    case ready
    case failed(EngineFailure)

    public var isReady: Bool { self == .ready }
}

/// Why an engine could not be loaded, as a value rather than a sentence: Core
/// imports Foundation only and produces no user-facing text, so the app turns
/// this into the line the menu shows, in the system language.
///
/// The distinction worth a user's attention is whether the network or the
/// files are at fault: a download that stopped continues from where it
/// stopped when they choose Retry, missing or damaged files are fetched
/// again, and only what is left is an engine problem.
public enum EngineFailure: Equatable, Sendable {
    /// The model did not finish downloading. Calling `load()` again resumes
    /// the `.partial` rather than starting over.
    case download(DownloadFailure)
    /// The cache is missing files. Calling `load()` again re-downloads them.
    case incompleteFiles
    /// The engine's own wording for anything else. Kept short; it is shown
    /// verbatim, untranslated, after a translated prefix.
    case loadFailed(detail: String)
}

/// What stopped the download.
public enum DownloadFailure: Equatable, Sendable {
    case serverError
    case rateLimited
    case stalled
    case damagedFile
    case noConnection
    case timedOut
    case tls
    case cancelled
    case network
    /// The downloader's own wording, shown verbatim and untranslated.
    case other(detail: String)
}

/// The errors an engine throws for reasons the app knows how to phrase.
public enum TranscriptionError: Error, Equatable, Sendable {
    /// Asked to transcribe before `load()` finished.
    case notLoaded
}
