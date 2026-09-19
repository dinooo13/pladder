import Foundation

/// Repairs near misses of the user's own words.
///
/// `DictionaryReplacer` only fires when the engine produced exactly the string
/// the user predicted. This one takes a list of *correct* terms and repairs
/// whatever came out: "Chat G P T" → "ChatGPT", "Charge B" → "ChargeBee",
/// "R and D" → "R&D". The terms are the dictionary entries whose `from` is
/// empty, so the Dictionary tab is the whole UI and there is no new screen.
///
/// How a match is decided:
///
/// - Every term is reduced once, at init, to a *key*: lowercased with every
///   character that is not a letter or digit removed, so "Claude Code" keys as
///   "claudecode". A term containing "&" also gets a second key with the "&"
///   spelled out, so "R&D" keys as both "rd" and "randd".
/// - The transcript is tokenised on whitespace and each position is tried as a
///   1-, 2-, 3- or 4-token n-gram, joined with nothing and reduced the same
///   way. Four is the longest term anybody spells out letter by letter
///   ("Chat G P T"); beyond that the candidate keys get long enough that the
///   distance threshold starts admitting whole phrases.
/// - Leading punctuation is split off the first token and trailing punctuation
///   off the last, and an n-gram never steps over punctuation in between, so
///   "chat, g p t" is three separate candidates rather than one.
/// - Score is the Levenshtein distance over the longer key length, times 0.3
///   when the Soundex codes agree, accepted below 0.18. The best score at a
///   position wins; ties go to the longer n-gram.
/// - A key of three characters or fewer must match exactly. This is the
///   false-positive guard: without it "the" turns into a configured "Tee" or
///   "TS", and one wrong word costs the user more than ten missed ones.
/// - The term is emitted verbatim unless it is entirely lowercase, in which
///   case the matched text's case pattern is mirrored — the same rule
///   `DictionaryReplacer.adjustCase` uses, so brand names keep their capitals.
/// - Terms whose key is not pure ASCII are skipped: Soundex is defined over
///   the English alphabet and would rank them by accident. They still work
///   through the exact replacer.
///
/// This sits on the release-to-paste path, so it is built to skip work rather
/// than to do it quickly: the keys are computed once in `init` and bucketed by
/// length, so a candidate only ever sees the handful of terms the length
/// prefilter could admit; the distance runs over byte arrays with two reusable
/// rows and abandons the matrix as soon as no path through it can clear the
/// threshold; and a transcript with no match is returned unchanged rather than
/// rebuilt. A hundred words against fifty terms costs a few hundred
/// microseconds, against an engine that takes a quarter of a second.
public struct CustomWordCorrector: TextProcessor {
    public static let processorID = "customWords"

    public let id = CustomWordCorrector.processorID
    public let displayName = "Custom words"
    public let detail = "Repairs near misses of the words you list in the Dictionary tab with an empty Heard as."

    /// Accept below this normalised distance.
    private static let threshold = 0.18
    /// Multiplier applied when the two Soundex codes agree.
    private static let soundexBonus = 0.3
    /// Keys this short or shorter only ever match exactly.
    private static let exactOnlyLength = 3
    /// Longest n-gram tried at each token position.
    private static let maxNGram = 4

    private let terms: [Term]

    /// Every term key bucketed by its length, index = length. The length
    /// prefilter then costs an index range instead of a scan over all the
    /// terms: a seven-character candidate never even looks at "elasticsearch".
    private let keysByLength: [[Key]]

    private struct Term: Sendable {
        let text: String
        /// True when the term carries no capitals of its own, so the matched
        /// text's case pattern may be mirrored onto it.
        let isLowercase: Bool
    }

    private struct Key: Sendable {
        /// Lowercase ASCII letters and digits only.
        let bytes: [UInt8]
        /// Four bytes, or empty when the key holds no letters.
        let soundex: [UInt8]
        /// Index into `terms`.
        let term: Int
    }

    public init(entries: [DictionaryEntry]) {
        var built: [Term] = []
        var keys: [Key] = []
        for entry in entries {
            guard entry.from.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let text = entry.to.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let primary = Self.key(for: text), !primary.isEmpty else { continue }

            let term = built.count
            built.append(Term(text: text, isLowercase: text == text.lowercased()))
            keys.append(Key(bytes: primary, soundex: Self.soundex(primary), term: term))
            if text.contains("&") {
                let spelled = text.replacingOccurrences(of: "&", with: "and")
                if let expanded = Self.key(for: spelled), !expanded.isEmpty, expanded != primary {
                    keys.append(Key(bytes: expanded, soundex: Self.soundex(expanded), term: term))
                }
            }
        }
        terms = built

        let widest = keys.map(\.bytes.count).max() ?? 0
        var buckets = [[Key]](repeating: [], count: widest + 1)
        for key in keys { buckets[key.bytes.count].append(key) }
        keysByLength = buckets
    }

    public func process(_ text: String) async throws -> String {
        apply(to: text)
    }

    public func apply(to text: String) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let tokens = Self.tokenise(text)
        guard !tokens.isEmpty else { return text }

        var rows = Rows()
        var candidate: [UInt8] = []
        var out = ""
        var copied = text.startIndex
        var changed = false
        var index = 0

        while index < tokens.count {
            var best: (score: Double, size: Int, term: Term)?

            // Ascending sizes, so an equal score from a longer n-gram replaces
            // the shorter one: ties go to the longer match.
            for size in 1...Self.maxNGram where index + size <= tokens.count {
                guard Self.spanIsUnbroken(tokens, from: index, size: size) else { continue }
                guard Self.candidateKey(tokens, from: index, size: size, into: &candidate) else { continue }
                guard let match = bestMatch(for: candidate, rows: &rows) else { continue }
                if best == nil || match.score <= best!.score {
                    best = (match.score, size, match.term)
                }
            }

            guard let best else {
                index += 1
                continue
            }

            let first = tokens[index]
            let last = tokens[index + best.size - 1]
            let matched = text[first.core.lowerBound..<last.core.upperBound]
            let replacement = Self.adjustCase(term: best.term, matched: matched)

            if !replacement.elementsEqual(matched) {
                out += text[copied..<first.core.lowerBound]
                out += replacement
                copied = last.core.upperBound
                changed = true
            }
            index += best.size
        }

        guard changed else { return text }
        out += text[copied...]
        return out
    }

    // MARK: Matching

    /// The best-scoring term for one candidate key, or nil when nothing clears
    /// the threshold. Ties go to the term the user listed first.
    private func bestMatch(for candidate: [UInt8], rows: inout Rows) -> (score: Double, term: Term)? {
        let length = candidate.count
        guard length > 0, keysByLength.count > 1 else { return nil }

        // The widest band of key lengths the length prefilter can admit. It is
        // deliberately a touch wide: `score` re-applies the exact rule, so slack
        // here costs one comparison and never changes the answer.
        let lower = max(0, length - max(2, length / 4))
        let upper = min(keysByLength.count - 1, (4 * (length + 2)) / 3 + 2)
        guard lower <= upper else { return nil }

        var bestScore = Self.threshold
        var bestTerm: Int?
        let candidateSoundex = Self.soundex(candidate)

        for bucket in lower...upper {
            for key in keysByLength[bucket] {
                guard let score = Self.score(
                    candidate: candidate,
                    candidateSoundex: candidateSoundex,
                    key: key,
                    rows: &rows
                ) else { continue }
                if score < bestScore || (bestTerm != nil && score == bestScore && key.term < bestTerm!) {
                    bestScore = score
                    bestTerm = key.term
                }
            }
        }
        guard let bestTerm else { return nil }
        return (bestScore, terms[bestTerm])
    }

    /// nil when the pair is rejected outright; otherwise the normalised score.
    private static func score(
        candidate: [UInt8],
        candidateSoundex: [UInt8],
        key: Key,
        rows: inout Rows
    ) -> Double? {
        let a = candidate
        let b = key.bytes
        let longer = max(a.count, b.count)
        let shorter = min(a.count, b.count)

        // Length prefilter: the cheapest way to skip the distance entirely.
        guard longer - shorter <= max(2, longer / 4) else { return nil }

        // Short keys only ever match exactly. "the" must never become "Tee".
        if a.count <= exactOnlyLength || b.count <= exactOnlyLength {
            return a == b ? 0 : nil
        }
        if a == b { return 0 }

        let factor = (!candidateSoundex.isEmpty && candidateSoundex == key.soundex) ? soundexBonus : 1
        // The largest distance that could still clear the threshold. Knowing it
        // up front lets the matrix give up the moment no path can get under it,
        // which is what happens for nearly every pair: two unrelated words of
        // similar length diverge within the first few rows.
        let bound = threshold * Double(longer) / factor
        var limit = Int(bound)
        if Double(limit) >= bound { limit -= 1 }
        guard limit >= 1 else { return nil }

        guard let distance = levenshtein(a, b, limit: limit, rows: &rows) else { return nil }
        return Double(distance) / Double(longer) * factor
    }

    /// Two reusable rows, so a whole `apply` allocates them once rather than
    /// once per comparison.
    private struct Rows {
        var previous: [Int] = []
        var current: [Int] = []
    }

    /// nil when the distance is certainly greater than `limit`, which is all
    /// the caller needs to know: such a pair can never be accepted.
    private static func levenshtein(_ a: [UInt8], _ b: [UInt8], limit: Int, rows: inout Rows) -> Int? {
        let width = b.count + 1
        if rows.previous.count < width {
            rows.previous = [Int](repeating: 0, count: width)
            rows.current = [Int](repeating: 0, count: width)
        }
        for j in 0..<width { rows.previous[j] = j }

        for i in 1...a.count {
            rows.current[0] = i
            let ai = a[i - 1]
            var rowMinimum = i
            for j in 1..<width {
                let cost = ai == b[j - 1] ? 0 : 1
                let deletion = rows.previous[j] + 1
                let insertion = rows.current[j - 1] + 1
                let substitution = rows.previous[j - 1] + cost
                let value = min(deletion, insertion, substitution)
                rows.current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            // A row's minimum never falls as the matrix grows, so once every
            // path through it costs more than the limit, nothing can recover.
            if rowMinimum > limit { return nil }
            swap(&rows.previous, &rows.current)
        }
        let distance = rows.previous[b.count]
        return distance <= limit ? distance : nil
    }

    // MARK: Keys

    /// Lowercase, letters and digits only. nil when a kept character is not
    /// ASCII.
    private static func key(for text: String) -> [UInt8]? {
        var out: [UInt8] = []
        for character in text where character.isLetter || character.isNumber {
            guard let ascii = character.asciiValue else { return nil }
            out.append(lowercased(ascii))
        }
        return out
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    /// Standard American Soundex over the letters of a key: the first letter
    /// followed by three digits, same-coded neighbours collapsed, "h" and "w"
    /// transparent, vowels separating. Empty when the key holds no letters.
    private static func soundex(_ key: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var previous: UInt8 = 0
        for byte in key {
            guard byte >= 97, byte <= 122 else { continue }
            let code = soundexCode(byte)
            if out.isEmpty {
                out.append(byte)
                previous = code
                continue
            }
            if code != 0, code != previous {
                out.append(48 + code)
                if out.count == 4 { break }
            }
            // "h" and "w" are transparent: the letters on either side still
            // count as neighbours. Every other letter, vowels included, resets.
            if byte != 104, byte != 119 { previous = code }
        }
        guard !out.isEmpty else { return [] }
        while out.count < 4 { out.append(48) }
        return out
    }

    private static func soundexCode(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 98, 102, 112, 118: return 1                      // b f p v
        case 99, 103, 106, 107, 113, 115, 120, 122: return 2  // c g j k q s x z
        case 100, 116: return 3                               // d t
        case 108: return 4                                    // l
        case 109, 110: return 5                               // m n
        case 114: return 6                                    // r
        default: return 0                                     // a e i o u y h w
        }
    }

    // MARK: Tokens

    private struct Token {
        /// The token with edge punctuation trimmed off. Empty for a token that
        /// is nothing but punctuation.
        let core: Range<String.Index>
        /// The token's key bytes, or nil when it holds a non-ASCII letter.
        let key: [UInt8]?
        let hasLeadingPunctuation: Bool
        let hasTrailingPunctuation: Bool
    }

    private static func tokenise(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            tokens.append(makeToken(text, index..<end))
            index = end
        }
        return tokens
    }

    private static func makeToken(_ text: String, _ range: Range<String.Index>) -> Token {
        var lower = range.lowerBound
        while lower < range.upperBound, !isWordCharacter(text[lower]) {
            lower = text.index(after: lower)
        }
        guard lower < range.upperBound else {
            // Nothing but punctuation. Counting it as both a leading and a
            // trailing boundary keeps any n-gram from consuming it.
            return Token(
                core: range.lowerBound..<range.lowerBound,
                key: [],
                hasLeadingPunctuation: true,
                hasTrailingPunctuation: true
            )
        }

        var upper = range.upperBound
        while upper > lower {
            let previous = text.index(before: upper)
            if isWordCharacter(text[previous]) { break }
            upper = previous
        }

        var key: [UInt8]? = []
        for character in text[lower..<upper] where isWordCharacter(character) {
            guard let ascii = character.asciiValue else {
                key = nil
                break
            }
            key!.append(lowercased(ascii))
        }

        return Token(
            core: lower..<upper,
            key: key,
            hasLeadingPunctuation: lower != range.lowerBound,
            hasTrailingPunctuation: upper != range.upperBound
        )
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// False when the span would step over punctuation: only the first token
    /// may carry leading punctuation and only the last may carry trailing.
    private static func spanIsUnbroken(_ tokens: [Token], from start: Int, size: Int) -> Bool {
        guard size > 1 else { return true }
        for offset in 0..<(size - 1) where tokens[start + offset].hasTrailingPunctuation {
            return false
        }
        for offset in 1..<size where tokens[start + offset].hasLeadingPunctuation {
            return false
        }
        return true
    }

    /// Fills `into` with the span's joined key. False when any token is
    /// non-ASCII or the span carries no word characters at all.
    private static func candidateKey(
        _ tokens: [Token],
        from start: Int,
        size: Int,
        into buffer: inout [UInt8]
    ) -> Bool {
        buffer.removeAll(keepingCapacity: true)
        for offset in 0..<size {
            guard let key = tokens[start + offset].key else { return false }
            buffer.append(contentsOf: key)
        }
        return !buffer.isEmpty
    }

    // MARK: Case

    /// A term with capitals of its own is a brand name and is emitted exactly
    /// as written. A term that is all lowercase mirrors the matched text.
    private static func adjustCase(term: Term, matched: Substring) -> String {
        guard term.isLowercase else { return term.text }
        let letters = matched.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return term.text.uppercased()
        }
        if let first = letters.first, first.isUppercase {
            return term.text.prefix(1).uppercased() + term.text.dropFirst()
        }
        return term.text
    }
}
