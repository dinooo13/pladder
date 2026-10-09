import Foundation
import NaturalLanguage

// A wrong guess deletes a real word (German "um", Spanish "eh"), a missed one only
// leaves a filler, so the floor is set to be sure rather than sensitive.
public enum TranscriptLanguage {
    // English, German and Spanish sentences of a few words, filler candidates included
    // ("eh no sé"), separate cleanly above this.
    public static let confidenceFloor = 0.8

    // On the release path: about 0.8 ms for a short sentence and 2 ms for 25 words on
    // an M1, and the language does not change mid-dictation.
    public static let sampleLength = 240

    public static func hint(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(sampleLength)))
        guard let top = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
              top.value >= confidenceFloor
        else { return nil }
        return top.key.rawValue
    }
}
