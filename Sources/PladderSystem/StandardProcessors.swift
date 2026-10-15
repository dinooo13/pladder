import Foundation
import PladderCore

// Fillers first, so the dictionary sees clean text; the fuzzy corrector after the
// exact replacer; spoken punctuation last, since the whitespace step would fold its
// paragraph breaks. Shared with `pladder-cli --process`.
public enum StandardProcessors {
    public struct Entry: Sendable {
        // Known without building the processor, which compiles regexes.
        public let id: String
        public let make: @Sendable (DictationSettings) -> any TextProcessor
    }

    public static let entries: [Entry] = [
        Entry(id: FillerRemover.processorID) { _ in
            FillerRemover(languageHint: { TranscriptLanguage.hint(for: $0) })
        },
        Entry(id: DictionaryReplacer.processorID) { DictionaryReplacer(entries: $0.dictionary) },
        Entry(id: CustomWordCorrector.processorID) { CustomWordCorrector(entries: $0.dictionary) },
        Entry(id: WhitespaceNormalizer.processorID) { _ in WhitespaceNormalizer() },
        Entry(id: SpokenPunctuation.processorID) { _ in
            SpokenPunctuation(languageHint: { TranscriptLanguage.hint(for: $0) })
        },
    ]

    public static func pipeline(for settings: DictationSettings) -> ProcessorPipeline {
        ProcessorPipeline(entries.map { $0.make(settings) })
    }
}
