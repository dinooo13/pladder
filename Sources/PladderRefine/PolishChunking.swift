import Foundation

/// How a long dictation is cut for a model with a bounded context. Each
/// polisher passes its own numbers: Apple's model has about 4k tokens,
/// S1-mini's context 2,048.
enum PolishChunking {
    /// The transcript as it is when it has `threshold` words or fewer, which
    /// is most dictations; otherwise windows of about `size` words, cut after
    /// a sentence end so no window starts mid-sentence.
    ///
    /// A transcript can come without sentence punctuation, a long one that
    /// never pauses or one the polish is asked to punctuate, and would then
    /// stay one window and overflow the context, so nothing at all got
    /// polished. A window that reaches `hardLimit(size)` words without a
    /// sentence end is cut there, between two words: a seam mid-sentence is
    /// a small loss next to the whole dictation going unpolished.
    static func chunks(of text: String, threshold: Int, size: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > threshold else { return [text] }
        let limit = hardLimit(size)
        var windows: [String] = []
        var current: [Substring] = []
        for word in words {
            current.append(word)
            let endsSentence = word.last.map { ".?!".contains($0) } ?? false
            if (current.count >= size && endsSentence) || current.count >= limit {
                windows.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { windows.append(current.joined(separator: " ")) }
        return windows
    }

    /// Half as long again as `size`: room for a long sentence to end before
    /// the forced cut, and still well inside either model's context.
    static func hardLimit(_ size: Int) -> Int {
        size + size / 2
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
