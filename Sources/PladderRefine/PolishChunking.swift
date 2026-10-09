import Foundation

enum PolishChunking {
    // Cut after a sentence end. A transcript without them would stay one window and
    // overflow the context, so a window reaching `hardLimit` is cut between two words.
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

    // Room for a long sentence to end before the forced cut, inside either model's context.
    static func hardLimit(_ size: Int) -> Int {
        size + size / 2
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
