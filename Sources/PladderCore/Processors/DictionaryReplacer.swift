import Foundation

// Longer `from` first, so "claude code" applies before "claude".
public struct DictionaryReplacer: TextProcessor {
    public static let processorID = "dictionary"

    public let id = DictionaryReplacer.processorID

    private let rules: [Rule]

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let matchCase: Bool
    }

    public init(entries: [DictionaryEntry]) {
        let cyclic = DictionaryEntry.cyclicIDs(in: entries)
        rules = entries
            .filter { !cyclic.contains($0.id) }
            .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.from.count > $1.from.count }
            .compactMap { entry in
                guard let regex = WholeWordPattern.regex(for: entry.from, caseInsensitive: !entry.matchCase) else {
                    return nil
                }
                return Rule(regex: regex, replacement: entry.to, matchCase: entry.matchCase)
            }
    }

    public func process(_ text: String) -> String {
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
