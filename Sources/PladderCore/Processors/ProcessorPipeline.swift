import Foundation

/// Runs an ordered list of processors, skipping any the settings disable.
public struct ProcessorPipeline: Sendable {
    public let processors: [any TextProcessor]

    public init(_ processors: [any TextProcessor]) {
        self.processors = processors
    }

    public func run(_ text: String, disabled: Set<String> = []) -> String {
        processors.reduce(text) { current, processor in
            disabled.contains(processor.id) ? current : processor.process(current)
        }
    }
}
