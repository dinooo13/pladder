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
///   "um", "emm", "eh", "ah". "er" is deliberately excluded, since it is the
///   German pronoun "he", and so is a single-m "em", an English word (see
///   `gatedTokens`). Spanish: "eh". German adds nothing on top of the
///   universal tier, since "äh"/"ähm" already cover it and bare "um"/"eh"
///   are real German words ("um acht Uhr", "das ist eh egal").
///
/// The evidence is a closure the app injects (`languageHint`), backed by
/// `NLLanguageRecognizer` outside `PladderCore`. It runs only when a gated
/// token is actually present, and nil — no opinion, or a language the
/// caller does not trust — means only the universal tier applies.
///
/// The filler is deleted together with a comma on either side and an
/// ellipsis after it, so "I, um, think" becomes "I think" and the space runs
/// that deletion leaves behind are collapsed. A full stop, question or
/// exclamation mark, colon or semicolon after it is not the filler's: it
/// ends the sentence the filler sat at the end of, so "I think so, um." keeps
/// its full stop. Only a filler that is a sentence of its own ("Done. Uh.
/// Next") takes its mark with it. A filler that opens the transcript carries
/// its capitalisation over to the next word. A token joined to a word by a
/// hyphen ("uh-oh", "uh-huh") is part of that word and stays.
public struct FillerRemover: TextProcessor {
    public static let processorID = "fillers"

    public let id = FillerRemover.processorID

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
    ///
    /// English "em" takes two m or more. A single-m "em" is an English word
    /// in every position a filler could sit: "an em dash", "1.5 em" in type,
    /// "let 'em in" for "them". No rule on its neighbours tells those from a
    /// hesitation, and the speech model writes that hesitation as "um" or
    /// "erm" far more often, so the bare form is left alone.
    private static let gatedTokens: [String: [String]] = [
        "en": ["u+m+", "e+m{2,}", "e+h+", "a+h+"],
        "es": ["e+h+"],
    ]

    private static let spaceRunPattern = "\\s{2,}"

    /// A comma before the filler, the filler, and a comma run or an ellipsis
    /// after it. A single full stop is left for `apply`, which knows whether
    /// it ends a sentence or only the filler. The hyphen lookarounds keep
    /// "uh-oh" whole, since `\b` sees a boundary at the hyphen. The one
    /// behind sits after the `\b`, not before it: the same check, but tried
    /// only where a word starts, so the scan costs what it did without it.
    private static func fillerPattern(_ tokens: [String]) -> String {
        "(?:,\\s*)?\\b(?<!-)(?:\(tokens.joined(separator: "|")))\\b(?!-)(?:\\s*(?:,+|\\.{2,}|…))?\\s*"
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
            let opensSentence = capitalizeNext || Self.endsSentence(out)
            capitalizeNext = opensSentence
            cursor = match.range.upperBound
            // The mark after the filler ends the sentence it sat in, so it
            // moves up to the word before: "Yes, uh. Okay" is "Yes. Okay". A
            // filler that is a sentence of its own takes its mark with it.
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

    /// The end of the run of sentence marks starting at `index`, or `index`
    /// when there is none. A run with a letter or digit straight after it is
    /// not one: ".5" is a number.
    private static func sentenceMarks(in ns: NSString, from index: Int) -> Int {
        var end = index
        while end < ns.length, ".?!;:".utf16.contains(ns.character(at: end)) { end += 1 }
        guard end > index, end < ns.length else { return end }
        guard let next = Unicode.Scalar(ns.character(at: end)), !CharacterSet.alphanumerics.contains(next)
        else { return index }
        return end
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
