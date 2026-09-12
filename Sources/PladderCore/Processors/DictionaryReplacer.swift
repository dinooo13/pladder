import Foundation

/// Applies user dictionary entries as whole-word replacements.
///
/// Rules:
/// - Matching is case-insensitive unless the entry sets `matchCase`.
/// - Only whole words match: "cat" does not match "concatenate".
/// - Multi-word `from` values are supported ("claude code").
/// - Longer `from` values win when entries overlap, so "claude code" is applied
///   before "claude".
/// - If the matched text started with a capital letter and the replacement is
///   all lowercase, the replacement's first letter is capitalised. Replacements
///   containing their own capitals (brand names) are left exactly as written.
public struct DictionaryReplacer: TextProcessor {
    public static let processorID = "dictionary"

    public let id = DictionaryReplacer.processorID
    public let displayName = "Dictionary"
    public let detail = "Applies your replacement rules. Edit them in the Dictionary tab."

    private let rules: [Rule]

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let matchCase: Bool
    }

    public init(entries: [DictionaryEntry]) {
        rules = entries
            .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.from.count > $1.from.count }
            .compactMap { entry in
                let from = entry.from.trimmingCharacters(in: .whitespaces)
                // Collapse runs of whitespace in the pattern so "claude  code"
                // and "claude code" both match.
                let words = from.split(whereSeparator: { $0.isWhitespace })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                let body = words.joined(separator: "\\s+")
                // \b needs a word character on the boundary. If `from` starts or
                // ends with punctuation, fall back to a lookaround on whitespace.
                let leading = from.first!.isLetter || from.first!.isNumber ? "\\b" : "(?<!\\S)"
                let trailing = from.last!.isLetter || from.last!.isNumber ? "\\b" : "(?!\\S)"
                let pattern = leading + body + trailing
                var options: NSRegularExpression.Options = []
                if !entry.matchCase { options.insert(.caseInsensitive) }
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                    return nil
                }
                return Rule(regex: regex, replacement: entry.to, matchCase: entry.matchCase)
            }
    }

    public func process(_ text: String) async throws -> String {
        apply(to: text)
    }

    public func apply(to text: String) -> String {
        var result = text
        for rule in rules {
            let ns = result as NSString
            let matches = rule.regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var out = ""
            var cursor = 0
            for match in matches {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let matched = ns.substring(with: match.range)
                out += Self.adjustCase(replacement: rule.replacement, matched: matched, matchCase: rule.matchCase)
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            result = out
        }
        return result
    }

    private static func adjustCase(replacement: String, matched: String, matchCase: Bool) -> String {
        guard !matchCase,
              let first = matched.first, first.isUppercase,
              replacement == replacement.lowercased(),
              let replFirst = replacement.first
        else { return replacement }
        return String(replFirst).uppercased() + replacement.dropFirst()
    }
}
