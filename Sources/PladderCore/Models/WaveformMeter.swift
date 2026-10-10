import Foundation

public struct WaveformMeter: Sendable {
    public let count: Int
    private var heights: [Float]

    private var envelope: [Float] {
        let centre = Float(count - 1) / 2
        return (0..<count).map { index in
            let distance = abs(Float(index) - centre) / centre
            return 1 - distance * distance * 0.5
        }
    }

    public private(set) var phase: Int = 0

    public init(count: Int, initialHeight: Float = 0.1) {
        self.count = count
        self.heights = Array(repeating: initialHeight, count: count)
    }

    // Ordinary speech swings the bars most of the way; loud peaks saturate.
    public static func amplitude(for level: Float) -> Float {
        let clamped = max(0, min(level, 1))
        return min(1, pow(clamped, 0.7) * 1.3)
    }

    @discardableResult
    public mutating func update(level: Float) -> [Float] {
        phase &+= 1
        let amplitude = Self.amplitude(for: level)
        let centre = Float(count - 1) / 2
        let phase = Float(self.phase) * 0.9
        heights = (0..<count).map { index in
            let envelope = 1 - pow(abs(Float(index) - centre) / centre, 2) * 0.5
            // Each bar follows its own slow wave, so the shape moves while the level is steady.
            let wobble = 0.65 + 0.35 * (0.5 + 0.5 * sin(Float(index) * 1.7 + phase))
            let target = 0.1 + amplitude * envelope * wobble * 0.9
            // Rise fast, fall slower, so peaks read clearly.
            let previous = heights[index]
            let weight: Float = target > previous ? 0.7 : 0.45
            return previous * (1 - weight) + target * weight
        }
        return heights
    }

    public var normalized: [Float] {
        let max = heights.max() ?? 1
        return max > 0 ? heights.map { $0 / max } : heights
    }
}
