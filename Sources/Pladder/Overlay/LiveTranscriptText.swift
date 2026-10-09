import AppKit
import SwiftUI
import PladderCore

// Every live pass returns a whole new string. Nothing animates: a cross-fade draws two
// layouts at once, unreadable at two passes a second. The prefix shared with the
// previous pass has stopped changing and is drawn primary, the rest secondary.
struct LiveTranscriptText: View {
    let text: String
    var hugs: Bool = false
    var width: CGFloat?
    static let maximumLines = 3


    // Only a colour, so lagging one pass behind costs nothing.
    @State private var previous = ""

    // SwiftUI's head truncation with a line limit keeps the first lines and drops the
    // middle, so the tail is cut here, at a word, against the font's real metrics.
    private var shown: String {
        guard let width, !hugs else { return text }
        return LiveTranscriptMetrics.tail(of: text, fittingLines: Self.maximumLines, width: width)
    }

    // Not two concatenated `Text`s, which macOS 26 deprecates.
    private var attributed: AttributedString {
        let shown = shown
        // The previous pass may have been cut to a different tail: compare from the end.
        var stable = shown.commonPrefix(with: previous.suffix(shown.count))
        // A prefix stopping inside a word would paint half of it grey.
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
            // The height is what the wrapping needs, one line to three, and the capsule grows
            // with it; a fixed box would leave a single line stranded at an edge.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: hugs ? width : nil, alignment: .leading)
            .frame(maxWidth: hugs ? nil : .infinity, alignment: .leading)
            .onChange(of: text) { old, _ in previous = old }
    }
}


// Runs while the key is held, never on the release path.
@MainActor
enum LiveTranscriptMetrics {
    static var font: NSFont { PillMetrics.nsFont }
    static let lineHeight: CGFloat = height(of: "Mg", width: .greatestFiniteMagnitude)

    static func tail(of text: String, fittingLines lines: Int, width: CGFloat) -> String {
        guard !text.isEmpty, width > 0, lines > 0 else { return text }
        let limit = lineHeight * CGFloat(lines) + 0.5
        guard height(of: text, width: width) > limit else { return text }

        let starts = wordStarts(in: text)
        guard starts.count > 1 else { return text }
        // Fitting is monotonic: the later a tail starts, the shorter it is.
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
