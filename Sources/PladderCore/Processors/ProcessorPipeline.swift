import Foundation

/// Runs an ordered list of processors, skipping any the settings disable.
public struct ProcessorPipeline: Sendable {
    public let processors: [any TextProcessor]

    public init(_ processors: [any TextProcessor]) {
        self.processors = processors
    }

    public func run(_ text: String, disabled: Set<String> = []) -> String {
        processors
            .filter { !disabled.contains($0.id) }
            .reduce(text) { current, processor in processor.process(current) }
    }
}
