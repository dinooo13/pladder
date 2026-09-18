import AppKit
import SwiftUI

/// How much of the live transcript fits in the pill.
///
/// The pill shows at most three lines, and the words worth showing are the
/// last ones. SwiftUI cannot do that on its own: `lineLimit(3)` with
/// `truncationMode(.head)` keeps the *first* two lines and ellipsises the
/// third, so the reader gets the oldest words, the newest ones, and a hole in
/// between. Cutting the string here instead gives a plain, continuous tail.
///
/// The measurement uses the same font the pill draws in, so the cut lands
/// where the text really wraps. It runs while the key is held, never on the
/// release-to-paste path.
@MainActor
enum LiveTranscriptMetrics {
    /// The 13 pt rounded medium the live row draws in, as an `NSFont` so it
    /// can be measured.
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: 13)
        else { return base }
        return rounded
    }()

    /// Height of one line of that font, laid out the way `boundingRect` lays
    /// the text out below.
    static let lineHeight: CGFloat = height(of: "Mg", width: .greatestFiniteMagnitude)

    /// The longest tail of `text`, starting at a word, that lays out in at
    /// most `lines` lines when wrapped at `width`. The whole text when it
    /// already fits.
    static func tail(of text: String, fittingLines lines: Int, width: CGFloat) -> String {
        guard !text.isEmpty, width > 0, lines > 0 else { return text }
        let limit = lineHeight * CGFloat(lines) + 0.5
        guard height(of: text, width: width) > limit else { return text }

        let starts = wordStarts(in: text)
        guard starts.count > 1 else { return text }
        // Fits is monotonic: the later a tail starts, the shorter it is, so
        // the first start that fits is the one to use.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high) / 2
            if height(of: String(text[starts[middle]...]), width: width) <= limit {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return String(text[starts[low]...])
    }

    /// Index of the first character of every word.
    private static func wordStarts(in text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var afterSpace = true
        for index in text.indices {
            let character = text[index]
            if afterSpace && !character.isWhitespace { starts.append(index) }
            afterSpace = character.isWhitespace
        }
        return starts
    }

    private static func height(of string: String, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        return attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    }
}
