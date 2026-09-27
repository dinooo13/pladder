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
    public static let factories: [@Sendable (Settings) -> any TextProcessor] = [
        { _ in FillerRemover(languageHint: { TranscriptLanguage.hint(for: $0) }) },
        { DictionaryReplacer(entries: $0.dictionary) },
        { CustomWordCorrector(entries: $0.dictionary) },
        { _ in WhitespaceNormalizer() },
        { _ in SpokenPunctuation(languageHint: { TranscriptLanguage.hint(for: $0) }) },
    ]
}
