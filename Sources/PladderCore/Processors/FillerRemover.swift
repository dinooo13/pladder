import Foundation

// Two tiers, so a real word is never taken for a filler: docs/ARCHITECTURE.md,
// "Processors".
public struct FillerRemover: TextProcessor {
    public static let processorID = "fillers"

    public let id = FillerRemover.processorID

    // Never a word in English, German or Spanish. "mm" is not here: it is millimetres
    // as often as a hum.
    private static let universalTokens = [
        "u+h+m*",    // uh, uhh, uhhh, uhm
        "u+m{2,}",   // umm, ummm — two or more m distinguishes this from
                     // the gated single-m "um"
        "e+h+m+",    // ehm
        "a+h+m+",    // ahm
        "e+r+m+",    // erm
        "h+m+",      // hm, hmm
        "m+h+m*",    // mh, mhm
        "ä+h+m*",    // äh, ähm
        "ö+h+m*",    // öh, öhm
    ]

    // Words in some language, removed only when `languageHint` names this one. Left out:
    // "er" (German "he"), a single-m "em" ("an em dash", "let 'em in"), and German "um"
    // and "eh", which are words ("um acht Uhr").
    private static let gatedTokens: [String: [String]] = [
        "en": ["u+m+", "e+m{2,}", "e+h+", "a+h+"],
        "es": ["e+h+"],
    ]

    private static let spaceRunPattern = "\\s{2,}"

    // A single full stop is left for `apply`, which knows whether it ends a sentence.
    // `\b` sees a boundary at a hyphen, so the lookarounds keep "uh-oh" whole; the one
    // behind sits after the `\b`, so it is tried only where a word starts.
    private static func fillerPattern(_ tokens: [String]) -> String {
        "(?:,\\s*)?\\b(?<!-)(?:\(tokens.joined(separator: "|")))\\b(?!-)(?:\\s*(?:,+|\\.{2,}|…))?\\s*"
    }

    private let universal: NSRegularExpression
    private let gated: [String: NSRegularExpression]
    // When this does not match, `languageHint` is never called.
    private let gatedCandidate: NSRegularExpression
    private let spaceRun: NSRegularExpression
    private let languageHint: (@Sendable (String) -> String?)?

    // `languageHint` returns an ISO 639-1 code only when confident. Nil applies only the
    // universal tier: failing closed keeps a real word intact.
    public init(languageHint: (@Sendable (String) -> String?)? = nil) {
        self.languageHint = languageHint
        universal = try! NSRegularExpression(
            pattern: Self.fillerPattern(Self.universalTokens),
            options: .caseInsensitive)

        var gatedRegexes: [String: NSRegularExpression] = [:]
        var allGatedTokens: [String] = []
        for (language, tokens) in Self.gatedTokens {
            gatedRegexes[language] = try! NSRegularExpression(
                pattern: Self.fillerPattern(tokens),
                options: .caseInsensitive)
            allGatedTokens.append(contentsOf: tokens)
        }
        gated = gatedRegexes
        gatedCandidate = try! NSRegularExpression(
            pattern: "\\b(?:\(allGatedTokens.joined(separator: "|")))\\b",
            options: .caseInsensitive)
        spaceRun = try! NSRegularExpression(pattern: Self.spaceRunPattern)
    }

    public func process(_ text: String) -> String {
        let afterUniversal = Self.apply(universal, spaceRun: spaceRun, to: text)
        guard !afterUniversal.isEmpty else { return afterUniversal }

        let ns = afterUniversal as NSString
        guard gatedCandidate.firstMatch(in: afterUniversal, range: NSRange(location: 0, length: ns.length)) != nil
        else { return afterUniversal }

        guard let languageHint,
              let language = languageHint(afterUniversal),
              let regex = gated[language]
        else { return afterUniversal }

        return Self.apply(regex, spaceRun: spaceRun, to: afterUniversal)
    }

    private static func apply(_ regex: NSRegularExpression, spaceRun: NSRegularExpression, to text: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        // Set by a filler that opened a sentence, spent on the next letter: "Test. Ähm, beim
        // Timeout" keeps "Beim" a sentence start.
        var capitalizeNext = false
        func append(_ segment: String) {
            guard capitalizeNext, let letter = segment.firstIndex(where: { !$0.isWhitespace }) else {
                out += segment
                return
            }
            capitalizeNext = false
            out += segment[..<letter]
            out += segment[letter].uppercased()
            out += segment[segment.index(after: letter)...]
        }
        for match in matches {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            append(before)
            let opensSentence = capitalizeNext || Self.endsSentence(out)
            capitalizeNext = opensSentence
            cursor = match.range.upperBound
            // The mark after the filler ends the sentence it sat in, so it moves up to the word
            // before: "Yes, uh. Okay" is "Yes. Okay". A filler alone in its sentence takes it along.
            let marks = Self.sentenceMarks(in: ns, from: cursor)
            if marks > cursor {
                if !opensSentence {
                    while out.last?.isWhitespace == true { out.removeLast() }
                    out += ns.substring(with: NSRange(location: cursor, length: marks - cursor))
                }
                cursor = marks
            }
            out += " "
        }
        append(ns.substring(from: cursor))

        return spaceRun.stringByReplacingMatches(
            in: out,
            range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // A run with a letter or digit straight after it is not one: ".5" is a number.
    private static func sentenceMarks(in ns: NSString, from index: Int) -> Int {
        var end = index
        while end < ns.length, ".?!;:".utf16.contains(ns.character(at: end)) { end += 1 }
        guard end > index, end < ns.length else { return end }
        guard let next = Unicode.Scalar(ns.character(at: end)), !CharacterSet.alphanumerics.contains(next)
        else { return index }
        return end
    }

    // An ellipsis trails off rather than ending a sentence.
    private static func endsSentence(_ text: String) -> Bool {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        guard end > text.startIndex else { return true }
        let head = text[..<end]
        switch head.last {
        case "!", "?": return true
        case ".": return !head.hasSuffix("..")
        default: return false
        }
    }
}
