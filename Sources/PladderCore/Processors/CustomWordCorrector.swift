import Foundation

// How a match is decided: docs/ARCHITECTURE.md, "Processors". On the release path,
// so it is built to skip work: keys bucketed by length at init, a distance that
// gives up early, and an unchanged transcript returned as it came.
public struct CustomWordCorrector: TextProcessor {
    public static let processorID = "customWords"

    public let id = CustomWordCorrector.processorID
    private static let threshold = 0.18
    private static let soundexBonus = 0.3
    private static let shortKeyLength = 5
    private static let shortKeySoundexEdits = 1
    private static let exactOnlyLength = 3
    // The longest term anybody spells out ("Chat G P T"); longer candidate keys let the
    // threshold admit whole phrases.
    private static let maxNGram = 4

    private let terms: [Term]
    private let isOrdinaryWord: @Sendable (String) -> Bool

    // Index = key length, so the length prefilter costs a range rather than a scan.
    private let keysByLength: [[Key]]

    private struct Term: Sendable {
        let text: String
        let isLowercase: Bool
    }

    private struct Key: Sendable {
        let bytes: [UInt8]
        let soundex: [UInt8]
        let term: Int
    }

    public init(
        entries: [DictionaryEntry],
        isOrdinaryWord: @escaping @Sendable (String) -> Bool = CustomWordCorrector.isCommonWord
    ) {
        self.isOrdinaryWord = isOrdinaryWord
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
        if !built.isEmpty { CommonWords.prepare() }

        let widest = keys.map(\.bytes.count).max() ?? 0
        var buckets = [[Key]](repeating: [], count: widest + 1)
        for key in keys { buckets[key.bytes.count].append(key) }
        keysByLength = buckets
    }

    public static func isCommonWord(_ word: String) -> Bool {
        CommonWords.all.contains(word)
    }

    public func process(_ text: String) -> String {
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

            // Ascending sizes, so an equal score from a longer n-gram wins.
            for size in 1...Self.maxNGram where index + size <= tokens.count {
                guard Self.spanIsUnbroken(tokens, from: index, size: size) else { continue }
                guard Self.candidateKey(tokens, from: index, size: size, into: &candidate) else { continue }
                guard let match = bestMatch(for: candidate, rows: &rows) else { continue }
                // An everyday word on its own is taken as said: "to the cloud" must not become "to
                // the Claude". Checked only once a match is found, which is rare.
                if size == 1, match.score > 0, isOrdinaryWord(String(decoding: candidate, as: UTF8.self)) {
                    continue
                }
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
            // A term that is itself a possessive ("McDonald's") takes the suffix back.
            var end = last.core.upperBound
            if let possessiveEnd = last.possessiveEnd, Self.endsInPossessive(best.term.text) {
                end = possessiveEnd
            }
            let matched = text[first.core.lowerBound..<end]
            let replacement = Self.adjustCase(term: best.term, matched: matched)

            if !replacement.elementsEqual(matched) {
                out += text[copied..<first.core.lowerBound]
                out += replacement
                copied = end
                changed = true
            }
            index += best.size
        }

        guard changed else { return text }
        out += text[copied...]
        return out
    }

    // MARK: Matching

    private func bestMatch(for candidate: [UInt8], rows: inout Rows) -> (score: Double, term: Term)? {
        let length = candidate.count
        guard length > 0, keysByLength.count > 1 else { return nil }

        // Deliberately a touch wide: `score` re-applies the exact rule, so slack here costs
        // one comparison and never changes the answer.
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

        guard longer - shorter <= max(2, longer / 4) else { return nil }

        // Short keys only ever match exactly: "the" must never become "Tee".
        if a.count <= exactOnlyLength || b.count <= exactOnlyLength {
            return a == b ? 0 : nil
        }
        if a == b { return 0 }

        let soundexAgrees = !candidateSoundex.isEmpty && candidateSoundex == key.soundex
        let factor = soundexAgrees ? soundexBonus : 1
        // The largest distance that could still clear the threshold, so the matrix can give
        // up early, as it does for nearly every pair.
        let bound = threshold * Double(longer) / factor
        var limit = Int(bound)
        if Double(limit) >= bound { limit -= 1 }
        // On a short key Soundex is nearly the whole word, so it buys one edit:
        // "rost" reaches "Rust", "roast" does not.
        if soundexAgrees, longer <= shortKeyLength { limit = min(limit, shortKeySoundexEdits) }
        guard limit >= 1 else { return nil }

        guard let distance = levenshtein(a, b, limit: limit, rows: &rows) else { return nil }
        return Double(distance) / Double(longer) * factor
    }

    private struct Rows {
        var previous: [Int] = []
        var current: [Int] = []
    }

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
            // A row's minimum never falls as the matrix grows, so nothing can recover.
            if rowMinimum > limit { return nil }
            swap(&rows.previous, &rows.current)
        }
        let distance = rows.previous[b.count]
        return distance <= limit ? distance : nil
    }

    // MARK: Keys

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
            // "h" (104) and "w" (119) are transparent; every other letter resets.
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
        let core: Range<String.Index>
        let key: [UInt8]?
        let hasLeadingPunctuation: Bool
        let hasTrailingPunctuation: Bool
        let possessiveEnd: String.Index?
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
            // Nothing but punctuation: a boundary on both sides, so no n-gram consumes it.
            return Token(
                core: range.lowerBound..<range.lowerBound,
                key: [],
                hasLeadingPunctuation: true,
                hasTrailingPunctuation: true,
                possessiveEnd: nil
            )
        }

        var upper = range.upperBound
        while upper > lower {
            let previous = text.index(before: upper)
            if isWordCharacter(text[previous]) { break }
            upper = previous
        }

        // A possessive "'s" is not part of the word: left in, "ask Claude's opinion" would
        // come out as "ask Claude opinion". Other contractions ("don't") keep their tail.
        var possessiveEnd: String.Index?
        let sIndex = text.index(before: upper)
        if sIndex > lower, text[sIndex] == "s" || text[sIndex] == "S" {
            let apostrophe = text.index(before: sIndex)
            if apostrophe > lower, text[apostrophe] == "'" || text[apostrophe] == "\u{2019}" {
                possessiveEnd = upper
                upper = apostrophe
            }
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
            hasTrailingPunctuation: upper != range.upperBound,
            possessiveEnd: possessiveEnd
        )
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func endsInPossessive(_ text: String) -> Bool {
        guard let last = text.last, last == "s" || last == "S" else { return false }
        let previous = text.dropLast().last
        return previous == "'" || previous == "\u{2019}"
    }

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
