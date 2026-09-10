import Foundation

/// Runs an ordered list of processors, skipping any the settings disable.
public struct ProcessorPipeline: Sendable {
    public let processors: [any TextProcessor]

    public init(_ processors: [any TextProcessor]) {
        self.processors = processors
    }

    /// Calls `prepare()` on every enabled processor, in order. Started when
    /// recording begins so a slow warm-up overlaps with the user speaking.
    public func prepare(disabled: Set<String> = []) async {
        for processor in processors where !disabled.contains(processor.id) {
            await processor.prepare()
        }
    }

    public func run(_ text: String, disabled: Set<String> = []) async throws -> String {
        var current = text
        for processor in processors where !disabled.contains(processor.id) {
            current = try await processor.process(current)
        }
        return current
    }

    /// The canonical pipeline: dictionary, the cleanup slot if one is selected
    /// and usable, whitespace last so it tidies whatever the others produced.
    ///
    /// Dictionary and whitespace stay gated by `disabledProcessors`; the
    /// cleanup slot is gated by `cleanupEnabled` alone.
    public static func standard(settings: Settings, cleanup: CleanupRegistry) -> ProcessorPipeline {
        var list: [any TextProcessor] = [DictionaryReplacer(entries: settings.dictionary)]
        if let processor = cleanup.makeProcessor(for: settings) { list.append(processor) }
        list.append(WhitespaceNormalizer())
        return ProcessorPipeline(list)
    }
}
