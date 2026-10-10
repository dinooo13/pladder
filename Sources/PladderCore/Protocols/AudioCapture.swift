import Foundation

public protocol AudioCapture: Actor {
    func start() async throws -> AsyncStream<Float>

    func drain() async -> [Float]

    // Only the samples after the last `drain()`.
    func stop() async -> CapturedAudio

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
