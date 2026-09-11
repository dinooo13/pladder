import Foundation

/// Word error rate between a reference script and a transcript, for the
/// benchmark. Both texts are normalised first (lowercased, punctuation
/// removed) so casing and punctuation choices the engine makes do not count
/// as errors; only the words do.
public enum WordErrorRate {
    /// Lowercases, drops punctuation and collapses whitespace so two texts
    /// that differ only in presentation compare equal word for word.
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[’']", with: "", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Substitutions + deletions + insertions, divided by the reference word
    /// count. 0 means a perfect match; can exceed 1 when the hypothesis has
    /// many extra words. Returns 0 for an empty reference and empty hypothesis.
    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : Double(hyp.count) }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    /// Levenshtein distance over word arrays, two rows of memory.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
