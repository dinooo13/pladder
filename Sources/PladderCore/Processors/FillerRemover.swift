import Foundation

/// Removes hesitation sounds ("uh", "um", German "äh"/"ähm", Spanish "eh", …)
/// from the transcript.
///
/// Two tiers, so a real word never gets mistaken for a filler:
///
/// - Universal tier: tokens that are not a word in English, German or
///   Spanish under any spelling — "uh", "uhm", "umm" (two or more m after
///   u, distinct from the gated single-m "um"), "ehm", "ahm", "erm", "hm",
///   "mh"/"mhm", "äh"/"ähm", "öh"/"öhm" — with elongation. Always removed.
///   "mm" alone is dropped from the list entirely: it is the unit
///   millimetre as often as it is a hum.
/// - Gated tier: tokens that collide with a real word in some language and
///   are only removed when the caller's language evidence says so. English:
///   "um", "em", "eh", "ah" ("er" is deliberately excluded — it is the
///   German pronoun "he"). Spanish: "eh". German adds nothing on top of the
///   universal tier, since "äh"/"ähm" already cover it and bare "um"/"eh"
///   are real German words ("um acht Uhr", "das ist eh egal").
///
/// The evidence is a closure the app injects (`languageHint`), backed by
/// `NLLanguageRecognizer` outside `PladderCore`. It runs only when a gated
/// token is actually present, and nil — no opinion, or a language the
/// caller does not trust — means only the universal tier applies.
///
/// The filler is deleted together with a comma on either side and its
/// trailing punctuation, so "I, um, think" becomes "I think" and the
/// space runs that deletion leaves behind are collapsed. A filler that opens
/// the transcript carries its capitalisation over to the next word.
public struct FillerRemover: TextProcessor {
    public static let processorID = "fillers"

    public let id = FillerRemover.processorID
    public let displayName = "Remove fillers"
    public let detail = "Strips hesitation sounds like “uh” and “um” from English, German and Spanish transcripts."

    /// Never a word in English, German or Spanish, so no language evidence
    /// is required.
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

    /// Only removed when `languageHint` names the language on the left.
    private static let gatedTokens: [String: [String]] = [
        "en": ["u+m+", "e+m+", "e+h+", "a+h+"],
        "es": ["e+h+"],
    ]

    private static let spaceRunPattern = "\\s{2,}"

    private static func fillerPattern(_ tokens: [String]) -> String {
        "(?:,\\s*)?\\b(?:\(tokens.joined(separator: "|")))\\b(?:\\s*[,.]+)?\\s*"
    }

    private let universal: NSRegularExpression
    private let gated: [String: NSRegularExpression]
    /// Cheap pre-check: the union of every gated token, across every
    /// language. When this does not match, `languageHint` is never called.
    private let gatedCandidate: NSRegularExpression
    private let spaceRun: NSRegularExpression
    private let languageHint: (@Sendable (String) -> String?)?

    /// - Parameter languageHint: Returns a lowercase ISO 639-1 code ("en",
    ///   "de", "es", …) for the dominant language of the text passed in,
    ///   only when confident, or nil otherwise. Nil — either the parameter
    ///   itself or the closure's return value — means only the universal
    ///   tier is applied: failing closed keeps a real word intact rather
    ///   than risk deleting one.
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

    public func process(_ text: String) async throws -> String {
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
        // Set by a filler that opened a sentence, and spent on the first
        // letter that follows it: "Test. Ähm, beim Timeout" keeps "Beim"
        // a sentence start, as a filler opening the transcript always did.
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
            if !capitalizeNext { capitalizeNext = Self.endsSentence(out) }
            cursor = match.range.upperBound
            out += " "
        }
        append(ns.substring(from: cursor))

        return spaceRun.stringByReplacingMatches(
            in: out,
            range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether text ends where a sentence may start: nothing yet, or a full
    /// stop, question or exclamation mark. An ellipsis trails off rather
    /// than ending one.
    private static func endsSentence(_ text: String) -> Bool {
        // From the end, since this runs once per filler on the text so far.
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
