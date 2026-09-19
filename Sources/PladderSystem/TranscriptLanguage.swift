import Foundation
import NaturalLanguage

/// Identifies the dominant language of a transcript for `FillerRemover`'s
/// gated filler tier — entirely on-device, via `NLLanguageRecognizer`.
///
/// `PladderCore` imports Foundation only, so this lives here and is wired in
/// as the `languageHint` closure `FillerRemover` takes. A wrong guess would
/// delete a real word (German "um", Spanish "eh"), while a missed guess only
/// leaves a filler in place, so the confidence floor is picked to be sure
/// rather than sensitive: see the throwaway check in the PR description for
/// the sentences it was picked against.
public enum TranscriptLanguage {
    /// Below this, `hint` returns nil rather than guess. English, German and
    /// Spanish sentences a few words long, including ones built entirely
    /// from filler candidates ("eh no sé"), separate cleanly above 0.8; nothing
    /// German or Spanish was seen reported as English at this floor.
    public static let confidenceFloor = 0.8

    /// How much of the transcript the recogniser reads. A call costs about
    /// 0.8 ms for a short sentence and 2 ms for 25 words on an M1, on the
    /// release-to-paste path, and the language does not change mid-dictation,
    /// so a long transcript is judged by its opening.
    public static let sampleLength = 240

    /// Returns a lowercase ISO 639-1 code ("en", "de", "es", …) for `text`'s
    /// dominant language, or nil when confidence does not clear
    /// `confidenceFloor`.
    public static func hint(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(sampleLength)))
        guard let top = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
              top.value >= confidenceFloor
        else { return nil }
        return top.key.rawValue
    }
}
