import Foundation

// Shared by `DictionaryReplacer` and `DictionaryEntry.cyclicIDs`, so the two agree
// on what a word boundary is.
enum WholeWordPattern {
    // Han, Kana, Hangul and Thai are written without spaces, so a word in them gets no
    // boundary at all. A punctuation edge ("c++", ".net") needs whitespace, punctuation
    // or nothing beside it, so "c++," matches and "c+++" and "asp.net" do not.
    static func regex(for word: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = words.joined(separator: "\\s+")

        let leading: String
        let trailing: String
        if containsUnspacedScript(trimmed) {
            leading = ""
            trailing = ""
        } else {
            let wordEdge = "[\\p{L}\\p{M}\\p{N}]"
            let punctuationEdge = "[^\\s\\p{P}]"
            leading = trimmed.first!.isLetter || trimmed.first!.isNumber
                ? "(?<!\(wordEdge))" : "(?<!\(punctuationEdge))"
            trailing = trimmed.last!.isLetter || trimmed.last!.isNumber
                ? "(?!\(wordEdge))" : "(?!\(punctuationEdge))"
        }

        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: leading + body + trailing, options: options)
    }

    static func containsUnspacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK Unified Ideographs (Han)
                0x3400...0x4DBF,    // CJK Unified Ideographs Extension A (Han)
                0xF900...0xFAFF,    // CJK Compatibility Ideographs (Han)
                0x3040...0x309F,    // Hiragana
                0x30A0...0x30FF,    // Katakana
                0xAC00...0xD7A3,    // Hangul Syllables
                0x1100...0x11FF,    // Hangul Jamo
                0x0E00...0x0E7F:    // Thai
                return true
            default:
                return false
            }
        }
    }
}
