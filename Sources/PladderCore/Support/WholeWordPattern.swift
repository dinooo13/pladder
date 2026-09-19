import Foundation

/// Builds the Unicode-aware whole-word regex shared by `DictionaryReplacer`
/// (which applies a rule) and `DictionaryEntry.cyclicIDs` (which checks
/// whether one rule's replacement contains another rule's trigger), so the
/// two agree on what counts as a word boundary.
enum WholeWordPattern {
    /// A regex matching `word` as a whole word inside arbitrary text, or nil
    /// if `word` is empty (after trimming) or fails to compile.
    ///
    /// Han, Hiragana, Katakana, Hangul and Thai are written without spaces
    /// between words, so a `word` containing any of those scripts gets no
    /// boundary assertion at all: "東京" must match inside "私は東京に行く"
    /// with nothing on either side. Everything else asserts directly on the
    /// Unicode categories that make up a word (`\p{L}\p{M}\p{N}`). ICU's
    /// `\b` already treats umlauts and accented letters as word characters;
    /// spelling the class out makes the rule explicit and keeps it the same
    /// in the cycle check. If `word` starts or ends with punctuation, that
    /// falls back to a lookaround on whitespace.
    static func regex(for word: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Collapse runs of whitespace in the pattern so "claude  code" and
        // "claude code" both match.
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
            leading = trimmed.first!.isLetter || trimmed.first!.isNumber
                ? "(?<!\(wordEdge))" : "(?<!\\S)"
            trailing = trimmed.last!.isLetter || trimmed.last!.isNumber
                ? "(?!\(wordEdge))" : "(?!\\S)"
        }

        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: leading + body + trailing, options: options)
    }

    /// True when `text` contains a character from a script conventionally
    /// written without spaces between words.
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
