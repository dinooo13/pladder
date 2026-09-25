import Foundation

/// Turns punctuation the speaker said out loud into the mark: "question
/// mark", "Fragezeichen", "signo de interrogación" become "?", and so on in
/// English, German and Spanish.
///
/// The speech model already turns most spoken marks into punctuation and
/// numbers into digits; what reaches this step is the rest, usually with the
/// model's own punctuation stuck to it ("verschieben? Fragezeichen."). That
/// punctuation is absorbed into the mark, so the result carries it once.
///
/// Only phrases that are never an ordinary word are taken. "period",
/// "Punkt" and "punto" are left alone, since "a trial period", "ein
/// wichtiger Punkt" and "el punto" are far more common than a dictated full
/// stop, and so are "colon" and "dos puntos". The one ambiguous phrase kept,
/// Spanish "coma", is a word in English too, so it needs the same language
/// evidence the filler remover uses. Between two digits "Komma" and "coma"
/// are the decimal comma: "3 Komma 5" becomes "3,5".
///
/// Runs after the whitespace step, which would otherwise fold the line
/// breaks of "new paragraph" back into spaces.
public struct SpokenPunctuation: TextProcessor {
    public static let processorID = "spoken-punctuation"

    public let id = SpokenPunctuation.processorID
    public let displayName = "Spoken punctuation"
    public let detail = "Turns spoken marks such as “comma”, “question mark” and “new paragraph” into the marks themselves, in English, German and Spanish."

    private enum Mark {
        case comma, fullStop, question, exclamation, colon, semicolon, paragraph

        var text: String {
            switch self {
            case .comma: ","
            case .fullStop: "."
            case .question: "?"
            case .exclamation: "!"
            case .colon: ":"
            case .semicolon: ";"
            case .paragraph: "\n\n"
            }
        }

        /// The next word starts a sentence.
        var endsSentence: Bool {
            switch self {
            case .fullStop, .question, .exclamation, .paragraph: true
            case .comma, .colon, .semicolon: false
            }
        }
    }

    /// Longer phrases first, so "punto y coma" is never read as "coma".
    private static let phrases: [(pattern: String, mark: Mark)] = [
        ("punto y coma", .semicolon),
        ("semicolon|semikolon", .semicolon),
        ("question mark|fragezeichen|signo de interrogaci[oó]n", .question),
        ("exclamation (?:mark|point)|ausrufezeichen|signo de exclamaci[oó]n", .exclamation),
        ("full stop|punto final", .fullStop),
        ("doppelpunkt", .colon),
        ("new paragraph|neuer absatz|nuevo p[aá]rrafo", .paragraph),
        ("comma|komma", .comma),
    ]

    /// Needs the language evidence; see the type's comment.
    private static let spanishComma = "coma"


    private let universal: [(regex: NSRegularExpression, mark: Mark)]
    private let spanish: NSRegularExpression
    /// Every phrase in one pass. Almost no dictation holds one, and this is
    /// the only scan such a dictation pays.
    private let candidate: NSRegularExpression
    private let languageHint: (@Sendable (String) -> String?)?

    /// - Parameter languageHint: The same closure the filler remover gets:
    ///   a confident ISO 639-1 code for the text, or nil. Called only when
    ///   the text holds "coma".
    public init(languageHint: (@Sendable (String) -> String?)? = nil) {
        self.languageHint = languageHint
        universal = Self.phrases.map { (try! NSRegularExpression(pattern: Self.pattern($0.pattern), options: .caseInsensitive), $0.mark) }
        spanish = try! NSRegularExpression(pattern: Self.pattern(Self.spanishComma), options: .caseInsensitive)
        let every = (Self.phrases.map(\.pattern) + [Self.spanishComma]).joined(separator: "|")
        candidate = try! NSRegularExpression(pattern: Self.pattern(every), options: .caseInsensitive)
    }

    /// The phrase as a whole word. The punctuation around it is taken by
    /// hand in `apply`: a pattern that starts with optional spaces cannot be
    /// scanned for quickly.
    private static func pattern(_ phrase: String) -> String {
        "\\b(?:\(phrase))\\b"
    }

    public func process(_ text: String) async throws -> String {
        guard candidate.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        else { return text }
        var result = text
        for (regex, mark) in universal {
            result = Self.apply(regex, mark: mark, to: result)
        }
        if result.range(of: Self.spanishComma, options: .caseInsensitive) != nil,
           let languageHint, languageHint(result) == "es"
        {
            result = Self.apply(spanish, mark: .comma, to: result)
        }
        return result
    }

    private static func apply(_ regex: NSRegularExpression, mark: Mark, to text: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        var capitalizeNext = false
        for match in matches {
            // The speech model's own punctuation around the phrase, and the
            // spaces on either side: "verschieben? Fragezeichen." is one mark.
            var start = match.range.location
            while start > cursor, isSpace(ns.character(at: start - 1)) { start -= 1 }
            while start > cursor, isStray(ns.character(at: start - 1)) { start -= 1 }
            while start > cursor, isSpace(ns.character(at: start - 1)) { start -= 1 }
            let lead = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            var before = ns.substring(with: NSRange(location: cursor, length: start - cursor))
            if capitalizeNext { before = capitalized(before); capitalizeNext = false }
            out += before
            cursor = match.range.upperBound
            let trailStart = cursor
            while cursor < ns.length, isStray(ns.character(at: cursor)) { cursor += 1 }
            let trailed = cursor > trailStart
            // Spaces after the phrase, up to the next word or line break.
            while cursor < ns.length, isSpace(ns.character(at: cursor)) { cursor += 1 }
            let next = cursor < ns.length ? ns.character(at: cursor) : nil

            if mark == .comma, out.last?.isNumber == true, lead.allSatisfy(\.isWhitespace),
               !trailed, let next, isDigit(next)
            {
                // "3 Komma 5": the decimal comma, no spaces.
                out += ","
                continue
            }
            if mark == .paragraph {
                // A paragraph keeps the sentence mark before it; only the
                // spaces go.
                out += lead.trimmingCharacters(in: .whitespaces)
                while out.last?.isWhitespace == true { out.removeLast() }
                out += out.isEmpty ? "" : mark.text
            } else {
                while out.last?.isWhitespace == true { out.removeLast() }
                out += mark.text
                // One space before the next word; none before a line break
                // or at the end.
                if let next, !isNewline(next) { out += " " }
            }
            capitalizeNext = mark.endsSentence
        }
        var tail = ns.substring(from: cursor)
        if capitalizeNext { tail = capitalized(tail) }
        out += tail
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 }
    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    /// Punctuation the speech model put around the spoken word.
    private static func isStray(_ c: unichar) -> Bool { ",.;:!?".utf16.contains(c) }

    /// The first letter upper-cased, if there is one before anything else.
    /// A word with a capital inside ("iPhone") is left as it is.
    private static func capitalized(_ text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }), text[index].isLetter else { return text }
        let next = text.index(after: index)
        if next < text.endIndex, text[next].isUppercase { return text }
        return text[..<index] + text[index].uppercased() + text[next...]
    }
}
