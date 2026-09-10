import Foundation

/// Decides whether a tidied transcript is close enough to the raw one to be
/// pasted, or whether the model wandered off and the raw text is safer.
///
/// Kept here, as a pure function on two strings, so the rules can be unit
/// tested without a language model on the machine. The filler list exists only
/// to judge how much the output is *allowed* to shrink; it never edits text.
public enum TidyAcceptance {
    public enum Rejection: Sendable, Equatable {
        case empty, tooLong
        /// `expected` is the original's token count, for the log line.
        case wordCountDrift(expected: Int, actual: Int)
        case contentLost(retained: Double)
    }

    public static let fillers: Set<String> = [
        "um", "uh", "uhm", "umm", "erm", "er", "hmm", "hm", "mhm", "mm",
        "ah", "äh", "ähm", "öhm", "hmmm",
    ]

    /// Lowercases, drops punctuation and symbols, and splits on whitespace, so
    /// "Hello, World!" and "hello world" compare equal.
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .filter { !($0.isPunctuation || $0.isSymbol) }
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    /// nil when accepted, otherwise the first rule that failed.
    public static func check(_ cleaned: String, against original: String) -> Rejection? {
        // 1. Nothing left, or wildly more than we started with.
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if cleaned.count > original.count * 2 { return .tooLong }

        let originalTokens = tokens(original)
        let n = originalTokens.count
        guard n > 0 else { return nil }
        let cleanedTokens = tokens(cleaned)

        // 2. Word count. Tidying may drop fillers and stutters, so subtract
        // those from the floor before allowing a small margin either way.
        let nonFiller = originalTokens.filter { !fillers.contains($0) }
        let fillerCount = n - nonFiller.count
        let dupCount = nonFiller.indices.dropFirst().count { nonFiller[$0] == nonFiller[$0 - 1] }
        let margin = max(2, Int((Double(n) * 0.10).rounded(.up)))
        let expectedMin = max(0, n - fillerCount - dupCount - margin)
        let expectedMax = n + 2
        let c = cleanedTokens.count
        if c < expectedMin || c > expectedMax {
            return .wordCountDrift(expected: n, actual: c)
        }

        // 3. Content. A rewrite can keep the length and still replace the
        // words, so require most of the original's words back, in order.
        var reference: [String] = []
        for token in nonFiller where token != reference.last { reference.append(token) }
        guard !reference.isEmpty else { return nil }
        let retained = Double(lcsLength(reference, cleanedTokens)) / Double(reference.count)
        if retained < 0.9 { return .contentLost(retained: retained) }
        return nil
    }

    /// Longest common subsequence length, plain O(n*m) DP over two rows.
    private static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
