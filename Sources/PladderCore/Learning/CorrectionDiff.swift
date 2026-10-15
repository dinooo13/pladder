import Foundation

// The rules a correction has to pass: docs/ARCHITECTURE.md, "Learned corrections".
public enum CorrectionDiff {
    static let maximumWordsPerSide = 2
    static let maximumPairLength = 256
    static let maximumHunks = 3
    // A reading must still hold this share of the window's words to count.
    static let anchorCoverage = 0.6
    static let rewriteFraction = 0.5
    // So a one- or two-word paste can still be corrected.
    static let rewriteAllowance = 2
    // Past this the reading is skipped rather than a quadratic table built; a
    // dictation near the 10 min cap can pass it, and then nothing is learned.
    static let maximumCells = 4_000_000

    public static func candidates(in observation: PasteObservation) -> [CorrectionPair] {
        let original = tagged(observation)
        let words = original.tokens.filter(\.isWord).count
        guard words > 0, original.pasted.contains(true) else { return [] }
        let required = Int((anchorCoverage * Double(words)).rounded(.down))

        for reading in observation.readings.reversed() {
            let target = tokens(reading)
            // An empty field is a sent message or a cleared one: the reading before it counts.
            guard target.contains(where: \.isWord),
                  let matches = alignment(original.tokens, target) else { continue }
            let matchedWords = matches.filter { original.tokens[$0.0].isWord }.count
            guard matchedWords >= required else { continue }
            return pairs(original: original, target: target, matches: matches)
        }
        return []
    }

    public static func candidates(pasted: String, final: String) -> [CorrectionPair] {
        candidates(in: PasteObservation(pasted: pasted, readings: [final]))
    }

    // MARK: Tokens

    struct Token: Equatable {
        var text: String
        var isWord: Bool
    }

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

    // The three parts are tokenised on their own, so a paste glued to a word
    // ("fooClaud") keeps its border.
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
            // A change reaching into the margin is the user editing their own text.
            guard a.allSatisfy({ original.pasted[$0] }) else { continue }
            substitutions += 1
            if let pair = pair(Array(source[a]), Array(target[b])) { out.append(pair) }
        }

        let allowance = max(rewriteAllowance, Int(rewriteFraction * Double(pastedTokens)))
        if substitutions > maximumHunks || changedPastedTokens > allowance { return [] }
        return out
    }

    private static func pair(_ heard: [Token], _ corrected: [Token]) -> CorrectionPair? {
        // A pair never crosses punctuation, and a hunk that also moved a comma is ambiguous.
        guard heard.allSatisfy(\.isWord), corrected.allSatisfy(\.isWord) else { return nil }
        guard (1...maximumWordsPerSide).contains(heard.count),
              (1...maximumWordsPerSide).contains(corrected.count) else { return nil }
        let from = heard.map(\.text).joined(separator: " ")
        let to = corrected.map(\.text).joined(separator: " ")
        guard from.count <= maximumPairLength, to.count <= maximumPairLength,
              from.lowercased() != to.lowercased() else { return nil }
        return CorrectionPair(heard: from, corrected: to)
    }
}
