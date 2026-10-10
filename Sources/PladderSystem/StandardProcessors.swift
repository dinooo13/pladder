import Foundation
import PladderCore

/// The app's text processors, shared with `pladder-cli --process` so the two
/// cannot drift apart.
///
/// Pipeline order: fillers go first so the dictionary sees cleaned text, the
/// fuzzy custom-word corrector runs after the exact replacer so it only sees
/// what the replacer could not fix, whitespace is tidied next, and spoken
/// punctuation comes last, because the whitespace step would fold its
/// paragraph breaks back into spaces. Each entry is a factory so a processor
/// that needs settings builds itself from them; nothing here knows which
/// processor that is.
public enum StandardProcessors {
    public struct Entry: Sendable {
        /// The processor's own `id`, known without building it: the settings
        /// list shows every processor and building one compiles regexes.
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

    /// The pipeline the app and the CLI run.
    public static func pipeline(for settings: DictationSettings) -> ProcessorPipeline {
        ProcessorPipeline(entries.map { $0.make(settings) })
    }
}
