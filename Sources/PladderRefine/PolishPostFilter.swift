import Foundation

public enum PolishPostFilter {
    // A model can emit these, and nobody can see them in the pasted text.
    static let invisibles: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    // Only a think block at the very start is the model's; the same tag later is the user's.
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
