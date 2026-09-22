import Foundation

/// What the model's answer has to lose before it can be pasted.
public enum PolishPostFilter {
    /// Zero width space, non-joiner and joiner, and the byte order mark: a
    /// model can emit them, and nobody can see them in the pasted text.
    static let invisibles: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    /// Strips a leading think block (`<think>…</think>` or
    /// `<thinking>…</thinking>`, any case), drops U+200B, U+200C, U+200D and
    /// U+FEFF wherever they are, and trims surrounding whitespace and
    /// newlines. Only a block at the very start is a think block; the same
    /// tag later in the text is the user's.
    public static func clean(_ output: String) -> String {
        var text = String(output.unicodeScalars.filter { !invisibles.contains(Character($0)) })
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["think", "thinking"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard text.range(of: open, options: [.caseInsensitive, .anchored]) != nil,
                  let end = text.range(of: close, options: .caseInsensitive) else { continue }
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }
}
