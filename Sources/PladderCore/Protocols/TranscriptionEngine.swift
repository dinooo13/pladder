import Foundation

public protocol TranscriptionEngine: Actor {
    // Also the settings key.
    nonisolated var id: EngineID { get }
    nonisolated var displayName: String { get }
    var status: EngineStatus { get }

    // Safe to call again; returns at once when already loaded.
    func load() async throws

    func transcribe(_ samples: [Float]) async throws -> Transcript

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
    case downloading(progress: Double?)
    case loading
    case ready
    case failed(EngineFailure)

    public var isReady: Bool { self == .ready }
}

public enum EngineFailure: Equatable, Sendable {
    // A `load()` after this resumes the partial download rather than starting over.
    case download(DownloadFailure)
    case incompleteFiles
    case loadFailed(detail: String)
}

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
    case other(detail: String)
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case notLoaded
}
