import Foundation

/// Runs an ordered list of processors, skipping any the settings disable.
public struct ProcessorPipeline: Sendable {
    public let processors: [any TextProcessor]

    public init(_ processors: [any TextProcessor]) {
        self.processors = processors
    }

    public func run(_ text: String, disabled: Set<String> = []) async throws -> String {
        var current = text
        for processor in processors where !disabled.contains(processor.id) {
            current = try await processor.process(current)
        }
        return current
    }
}
