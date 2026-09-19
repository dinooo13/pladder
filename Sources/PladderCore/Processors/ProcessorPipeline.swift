import Foundation

/// Runs an ordered list of processors, skipping any the settings disable.
///
/// Fails open: a processor that throws is skipped and the text carries on
/// unchanged from the previous stage, rather than losing the whole
/// dictation over one optional cleanup step.
public struct ProcessorPipeline: Sendable {
    public let processors: [any TextProcessor]
    private let onFailure: (@Sendable (String, any Error) -> Void)?

    public init(
        _ processors: [any TextProcessor],
        onFailure: (@Sendable (String, any Error) -> Void)? = nil
    ) {
        self.processors = processors
        self.onFailure = onFailure
    }

    public func run(_ text: String, disabled: Set<String> = []) async -> String {
        var current = text
        for processor in processors where !disabled.contains(processor.id) {
            do {
                current = try await processor.process(current)
            } catch {
                onFailure?(processor.id, error)
            }
        }
        return current
    }
}
