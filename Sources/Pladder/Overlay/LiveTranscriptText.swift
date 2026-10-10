import AppKit
import SwiftUI
import PladderCore

/// The words so far, with the part that has not settled yet in secondary.
///
/// Every live pass re-decodes the audio and returns a whole new string, so the
/// layout can change anywhere in it. Nothing here animates: a cross-fade
/// between two layouts draws both at once, which is unreadable at two passes a
/// second. Each pass simply replaces the text. The only thing carried between
/// passes is the common prefix with the previous string, which is the part the
/// engine has stopped changing; what came after it is drawn in secondary, so
/// the eye can see where the settled words end.
struct LiveTranscriptText: View {
    let text: String
    /// A replica in a settings card has no row to fill, so it hugs its sample
    /// text, wrapped at `width` onto at most two lines and never trimmed.
    var hugs: Bool = false
    /// How wide the words may run before they wrap, so the view can work out
    /// how much of the tail fits.
    var width: CGFloat?

    /// Three lines of 13 pt is as much as the pill can show without turning
    /// into a window.
    static let maximumLines = 3


    /// The text of the previous pass, for the settled/unsettled split. It is
    /// only a colour, so lagging one pass behind costs nothing.
    @State private var previous = ""

    /// The part of the text that is shown: the whole of it while it fits in
    /// three lines, and its tail once it does not. SwiftUI's own head
    /// truncation is no use here — with a line limit it keeps the first lines
    /// and ellipsises the last one, which shows the oldest words and the
    /// newest ones with the middle missing — so the cut is made here, at a
    /// word boundary, against the font's real metrics.
    private var shown: String {
        guard let width, !hugs else { return text }
        return LiveTranscriptMetrics.tail(of: text, fittingLines: Self.maximumLines, width: width)
    }

    /// One `AttributedString` rather than two concatenated `Text`s, which
    /// macOS 26 deprecates.
    private var attributed: AttributedString {
        let shown = shown
        // The previous pass may have been trimmed to a different tail, so
        // compare like with like from the end.
        var stable = shown.commonPrefix(with: previous.suffix(shown.count))
        // A prefix that stops inside a word would paint half of it grey, so
        // back up to the end of the last whole word.
        if stable.count < shown.count, let lastSpace = stable.lastIndex(where: \.isWhitespace) {
            stable = String(stable[..<lastSpace])
        }
        var settled = AttributedString(stable)
        settled.foregroundColor = .primary
        var unsettled = AttributedString(shown.dropFirst(stable.count))
        unsettled.foregroundColor = .secondary
        return settled + unsettled
    }

    var body: some View {
        Text(attributed)
            .font(PillMetrics.font)
            .multilineTextAlignment(.leading)
            // A backstop only: `shown` has already been cut to fit.
            .lineLimit(hugs ? 2 : Self.maximumLines)
            // The row is a fixed width and the text takes what the dot and the
            // meter leave of it, wrapping there. Its height is whatever that
            // wrapping needs, one line to three, and the capsule grows with
            // it; a fixed box would leave a single line stranded at an edge.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: hugs ? width : nil, alignment: .leading)
            .frame(maxWidth: hugs ? nil : .infinity, alignment: .leading)
            .onChange(of: text) { old, _ in previous = old }
    }
}


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
    /// The face the live row draws in, as an `NSFont` so it can be measured.
    static var font: NSFont { PillMetrics.nsFont }

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
