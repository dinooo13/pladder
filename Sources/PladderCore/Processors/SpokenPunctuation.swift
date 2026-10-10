import Foundation

// Which phrases count as a dictated mark: docs/ARCHITECTURE.md, "Processors".
public struct SpokenPunctuation: TextProcessor {
    public static let processorID = "spoken-punctuation"

    public let id = SpokenPunctuation.processorID

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

        var endsSentence: Bool {
            switch self {
            case .fullStop, .question, .exclamation, .paragraph: true
            case .comma, .colon, .semicolon: false
            }
        }
    }

    // Longer phrases first, so "punto y coma" is never read as "coma".
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

    // An English word too, so it needs the language evidence.
    private static let spanishComma = "coma"

    // Words that never end a clause, so a phrase after one is a noun. "a" is the
    // letter when it is a capital in mid-sentence ("plan A comma").
    private static let articles: Set<String> = [
        "a", "an", "the",
        "eine", "einen", "einem",
        "un", "una", "el", "la", "los", "las",
    ]

    // They end a clause as well, so they count only with one of `markAdjectives` after them:
    // pronouns, and "ein", the separable prefix of "einschalten" and "einladen".
    private static let demonstratives: Set<String> = ["this", "that", "der", "die", "das", "dem", "den", "ein"]

    // A closed list: an open guess would take the noun in "the end comma" for one.
    // German entries are stems, matched with their ending taken off.
    private static let markAdjectives: Set<String> = [
        "oxford", "serial", "decimal", "extra", "missing", "stray", "trailing", "inverted",
        "misplaced", "unnecessary", "superfluous", "big", "huge", "giant", "little", "small",
        "tiny", "double", "single", "wrong",
        "groß", "klein", "fehlend", "zusätzlich", "überflüssig", "doppelt", "einzeln", "falsch",
        "riesig", "dick",
        "gran", "pequeño", "pequeña", "simple",
    ]
    private static let germanEndings = ["e", "em", "en", "er", "es"]

    private let universal: [(regex: NSRegularExpression, mark: Mark)]
    private let spanish: NSRegularExpression
    // Almost no dictation holds a phrase, and this is the only scan such a one pays.
    private let candidate: NSRegularExpression
    private let languageHint: (@Sendable (String) -> String?)?

    public init(languageHint: (@Sendable (String) -> String?)? = nil) {
        self.languageHint = languageHint
        universal = Self.phrases.map { (try! NSRegularExpression(pattern: Self.pattern($0.pattern), options: .caseInsensitive), $0.mark) }
        spanish = try! NSRegularExpression(pattern: Self.pattern(Self.spanishComma), options: .caseInsensitive)
        let every = (Self.phrases.map(\.pattern) + [Self.spanishComma]).joined(separator: "|")
        candidate = try! NSRegularExpression(pattern: Self.pattern(every), options: .caseInsensitive)
    }

    // The punctuation around a phrase is taken by hand in `apply`: a pattern starting
    // with optional spaces cannot be scanned for quickly.
    private static func pattern(_ phrase: String) -> String {
        "\\b(?:\(phrase))\\b"
    }

    public func process(_ text: String) -> String {
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
        var converted = false
        for match in matches {
            // Left in the text: the next segment copies it with its neighbours.
            if namesTheMark(ns, at: match.range.location) { continue }
            converted = true
            // The speech model's own punctuation around the phrase goes too:
            // "verschieben? Fragezeichen." is one mark.
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
                // A paragraph keeps the sentence mark before it; only the spaces go.
                out += lead.trimmingCharacters(in: .whitespaces)
                while out.last?.isWhitespace == true { out.removeLast() }
                out += out.isEmpty ? "" : mark.text
            } else {
                while out.last?.isWhitespace == true { out.removeLast() }
                out += mark.text
                if let next, !isNewline(next) { out += " " }
            }
            capitalizeNext = mark.endsSentence
        }
        guard converted else { return text }
        var tail = ns.substring(from: cursor)
        if capitalizeNext { tail = capitalized(tail) }
        out += tail
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func namesTheMark(_ ns: NSString, at location: Int) -> Bool {
        guard let previous = word(in: ns, endingAt: location) else { return false }
        let text = ns.substring(with: previous)
        if isArticle(text, in: ns, at: previous.location) { return true }
        guard isMarkAdjective(text.lowercased()), let first = word(in: ns, endingAt: previous.location) else {
            return false
        }
        let determiner = ns.substring(with: first)
        return isArticle(determiner, in: ns, at: first.location) || demonstratives.contains(determiner.lowercased())
    }

    private static func isArticle(_ word: String, in ns: NSString, at location: Int) -> Bool {
        guard articles.contains(word.lowercased()) else { return false }
        guard word == "A" else { return true }
        // A capital "A" is the article only where a sentence starts.
        var index = location
        while index > 0, isSpace(ns.character(at: index - 1)) { index -= 1 }
        return index == 0 || ".!?\n\r".utf16.contains(ns.character(at: index - 1))
    }

    private static func isMarkAdjective(_ word: String) -> Bool {
        if markAdjectives.contains(word) { return true }
        return germanEndings.contains { word.hasSuffix($0) && markAdjectives.contains(String(word.dropLast($0.count))) }
    }

    private static func word(in ns: NSString, endingAt location: Int) -> NSRange? {
        var end = location
        while end > 0, isSpace(ns.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0, isLetter(ns.character(at: start - 1)) { start -= 1 }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }

    private static func isLetter(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map(CharacterSet.letters.contains) ?? false
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 }
    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isStray(_ c: unichar) -> Bool { ",.;:!?".utf16.contains(c) }

    private static func capitalized(_ text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }), text[index].isLetter else { return text }
        let next = text.index(after: index)
        if next < text.endIndex, text[next].isUppercase { return text }
        return text[..<index] + text[index].uppercased() + text[next...]
    }
}
