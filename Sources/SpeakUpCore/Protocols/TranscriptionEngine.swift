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
    case failed(message: String)

    public var isReady: Bool { self == .ready }
}
