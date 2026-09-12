import Foundation

/// Development engine that returns fixed text after a short delay. Used to prove
/// the hotkey, overlay, and paste path before any model is involved, and by
/// tests.
public actor EchoEngine: TranscriptionEngine {
    public static let engineID = EngineID("echo")

    public nonisolated let id = EchoEngine.engineID
    public nonisolated let displayName = "Echo (testing)"
    public private(set) var status: EngineStatus = .unloaded

    private let text: String
    private let delay: Duration

    public init(text: String = "Hello from Pladder.", delay: Duration = .milliseconds(200)) {
        self.text = text
        self.delay = delay
    }

    public func load() async throws {
        guard status != .ready else { return }
        status = .loading
        try await Task.sleep(for: delay)
        status = .ready
    }

    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        let started = Date()
        try await Task.sleep(for: delay)
        return Transcript(
            text: text,
            audioDuration: Double(samples.count) / CapturedAudio.sampleRate,
            processingTime: Date().timeIntervalSince(started),
            engineID: id
        )
    }

    public func unload() {
        status = .unloaded
    }
}
