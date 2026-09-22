import Foundation

/// Finds the words the user corrected by hand in a pasted dictation.
///
/// Pure and off the release-to-paste path: it runs up to a minute after the
/// paste, on the learner's background task.
///
/// How a pair is found:
///
/// - Text is cut into tokens. A *word* is a run of letters and digits, with
///   an apostrophe or hyphen inside it ("don't", "e-mail") kept as part of
///   it; every other visible character is a *punctuation* token of its own;
///   whitespace only separates. So a correction never crosses a comma or a
///   full stop.
/// - The window as it was when the paste was found (margin, paste, margin) is
///   aligned against a later reading of the same window with a
///   longest-common-subsequence over tokens, case-sensitively. What is left
///   over at each point of the alignment is a *hunk*.
/// - The reading used is the last one that still holds most of the window
///   (`anchorCoverage`). An emptied field (a chat message sent), a cleared
///   one, or a terminal that scrolled fails that and the reading before it is
///   used instead.
/// - A hunk is a candidate only when both sides are one or two words, it
///   lies wholly inside the pasted text, it holds no punctuation, each side
///   is at most `maximumPairLength` characters without control characters,
///   and it is more than a change of case (those are the issue's rule: a
///   capital is a matter of the sentence, not of the word).
/// - Insertions and deletions are ignored: adding or dropping a word is
///   editing, not correcting a misheard one.
/// - More than `maximumHunks` changes inside the paste, or more than half its
///   tokens changed, is a rewrite and yields nothing at all rather than the
///   first few.
public enum CorrectionDiff {
    static let maximumWordsPerSide = 2
    static let maximumPairLength = 256
    static let maximumHunks = 3
    /// A reading must still hold this share of the window's words to count.
    static let anchorCoverage = 0.6
    /// Past this share of changed tokens the paste was rewritten.
    static let rewriteFraction = 0.5
    /// Up to this many changed tokens never count as a rewrite, so a one- or
    /// two-word paste can still be corrected.
    static let rewriteAllowance = 2
    /// The alignment table's bound; past it the reading is skipped rather
    /// than a quadratic table built. A 120 s dictation is far below it.
    static let maximumCells = 4_000_000

    /// Pairs in text order, empty when there is nothing to learn.
    public static func candidates(in observation: PasteObservation) -> [CorrectionPair] {
        let original = tagged(observation)
        let words = original.tokens.filter(\.isWord).count
        guard words > 0, original.pasted.contains(true) else { return [] }
        let required = Int((anchorCoverage * Double(words)).rounded(.down))

        for reading in observation.readings.reversed() {
            let target = tokens(reading)
            // An empty field is never the last word: it is a sent message or a
            // cleared field, and the reading before it is the one to diff.
            guard target.contains(where: \.isWord),
                  let matches = alignment(original.tokens, target) else { continue }
            let matchedWords = matches.filter { original.tokens[$0.0].isWord }.count
            guard matchedWords >= required else { continue }
            return pairs(original: original, target: target, matches: matches)
        }
        return []
    }

    /// A paste with no margin and one reading; what most tests call.
    public static func candidates(pasted: String, final: String) -> [CorrectionPair] {
        candidates(in: PasteObservation(pasted: pasted, readings: [final]))
    }

    // MARK: Tokens

    struct Token: Equatable {
        var text: String
        var isWord: Bool
    }

    /// Characters that stay inside a word when a word character follows.
    private static let joiners: Set<Character> = ["'", "\u{2019}", "-"]

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func tokens(_ text: String) -> [Token] {
        let characters = Array(text)
        var out: [Token] = []
        var i = 0
        while i < characters.count {
            let character = characters[i]
            if character.isWhitespace {
                i += 1
            } else if isWordCharacter(character) {
                var j = i + 1
                while j < characters.count {
                    if isWordCharacter(characters[j]) {
                        j += 1
                    } else if joiners.contains(characters[j]), j + 1 < characters.count,
                              isWordCharacter(characters[j + 1]) {
                        j += 2
                    } else {
                        break
                    }
                }
                out.append(Token(text: String(characters[i..<j]), isWord: true))
                i = j
            } else {
                out.append(Token(text: String(character), isWord: false))
                i += 1
            }
        }
        return out
    }

    /// The anchor-time window as tokens, each marked with whether it belongs
    /// to the pasted text. The three parts are tokenised on their own, so a
    /// paste glued to a word ("fooClaud") keeps its border.
    private static func tagged(_ observation: PasteObservation) -> (tokens: [Token], pasted: [Bool]) {
        let before = tokens(observation.before)
        let pasted = tokens(observation.pasted)
        let after = tokens(observation.after)
        return (
            before + pasted + after,
            Array(repeating: false, count: before.count)
                + Array(repeating: true, count: pasted.count)
                + Array(repeating: false, count: after.count)
        )
    }

    // MARK: Alignment

    /// Index pairs of matched tokens, increasing on both sides; nil when the
    /// table would be too large. The common head and tail are matched
    /// directly, so the table only covers the stretch that changed.
    static func alignment(_ a: [Token], _ b: [Token]) -> [(Int, Int)]? {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        let n = a.count - head - tail
        let m = b.count - head - tail
        guard (n + 1) * (m + 1) <= maximumCells else { return nil }

        var matches: [(Int, Int)] = (0..<head).map { ($0, $0) }
        if n > 0, m > 0 {
            // lengths[i][j]: LCS of a[head + i...] and b[head + j...], flattened.
            let width = m + 1
            var lengths = [Int32](repeating: 0, count: (n + 1) * width)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i * width + j] = a[head + i] == b[head + j]
                        ? lengths[(i + 1) * width + j + 1] + 1
                        : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < n, j < m {
                if a[head + i] == b[head + j] {
                    matches.append((head + i, head + j))
                    i += 1
                    j += 1
                } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        for k in 0..<tail {
            matches.append((a.count - tail + k, b.count - tail + k))
        }
        return matches
    }

    // MARK: Hunks

    private static func pairs(
        original: (tokens: [Token], pasted: [Bool]),
        target: [Token],
        matches: [(Int, Int)]
    ) -> [CorrectionPair] {
        let source = original.tokens
        var hunks: [(Range<Int>, Range<Int>)] = []
        var previous = (-1, -1)
        for match in matches + [(source.count, target.count)] {
            let a = (previous.0 + 1)..<match.0
            let b = (previous.1 + 1)..<match.1
            if !a.isEmpty || !b.isEmpty { hunks.append((a, b)) }
            previous = match
        }

        let pastedTokens = original.pasted.filter { $0 }.count
        var changedPastedTokens = 0
        var substitutions = 0
        var out: [CorrectionPair] = []
        for (a, b) in hunks {
            changedPastedTokens += a.filter { original.pasted[$0] }.count
            // Insertions and deletions are editing, not correcting.
            guard !a.isEmpty, !b.isEmpty else { continue }
            // Wholly inside the paste: a change that reaches into the margin
            // is the user editing their own text, or noise at the border.
            guard a.allSatisfy({ original.pasted[$0] }) else { continue }
            substitutions += 1
            if let pair = pair(Array(source[a]), Array(target[b])) { out.append(pair) }
        }

        let allowance = max(rewriteAllowance, Int(rewriteFraction * Double(pastedTokens)))
        if substitutions > maximumHunks || changedPastedTokens > allowance { return [] }
        return out
    }

    /// The rules a single substitution has to pass.
    private static func pair(_ heard: [Token], _ corrected: [Token]) -> CorrectionPair? {
        // A pair never crosses punctuation, and a hunk that also moved a
        // comma is ambiguous.
        guard heard.allSatisfy(\.isWord), corrected.allSatisfy(\.isWord) else { return nil }
        guard (1...maximumWordsPerSide).contains(heard.count),
              (1...maximumWordsPerSide).contains(corrected.count) else { return nil }
        let from = heard.map(\.text).joined(separator: " ")
        let to = corrected.map(\.text).joined(separator: " ")
        guard from.count <= maximumPairLength, to.count <= maximumPairLength,
              !from.contains(","),
              !hasControlCharacter(from), !hasControlCharacter(to),
              from != to,
              from.lowercased() != to.lowercased() else { return nil }
        return CorrectionPair(heard: from, corrected: to)
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
