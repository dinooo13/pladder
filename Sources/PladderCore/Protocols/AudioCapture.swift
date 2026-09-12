import Foundation

/// Captures microphone audio and returns it as 16 kHz mono Float32 PCM.
///
/// `start()` returns a stream of level updates for the overlay meter. The
/// captured samples are accumulated internally and returned by `stop()`.
public protocol AudioCapture: Actor {
    /// Begin recording. Emits input level (0...1, roughly RMS) while recording.
    func start() async throws -> AsyncStream<Float>

    /// Stop recording and return everything captured since `start()`.
    func stop() async -> CapturedAudio

    /// Prepare hardware ahead of time so the first `start()` is instant.
    func warmUp() async throws
}

public struct CapturedAudio: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval {
        Double(samples.count) / Self.sampleRate
    }

    public var isEmpty: Bool { samples.isEmpty }
}
