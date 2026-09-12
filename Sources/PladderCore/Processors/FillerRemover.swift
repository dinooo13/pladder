import Foundation

/// Removes hesitation sounds ("uh", "um", German "äh"/"ähm", Spanish "eh", …)
/// from the transcript.
///
/// Conservative by design: only particles that are never content words in
/// English, German or Spanish are matched. Words like "like", "you know",
/// "eigentlich" or "pues" are deliberately left alone. Elongated forms
/// ("uhhh", "ähmm") are covered by repeating-letter patterns.
///
/// The filler is deleted together with a comma on either side and its
/// trailing punctuation, so "I, um, think" becomes "I think" and the
/// space runs that deletion leaves behind are collapsed. A filler that opens
/// the transcript carries its capitalisation over to the next word.
public struct FillerRemover: TextProcessor {
    public static let processorID = "fillers"

    public let id = FillerRemover.processorID
    public let displayName = "Remove fillers"
    public let detail = "Strips hesitation sounds like “uh” and “um” from English, German and Spanish transcripts."

    private static let fillerPattern =
        "(?:,\\s*)?\\b(?:u+h+|u+m+|e+h+|e+m+|e+r+m+|m+h+|m+m+|h+m+|ä+h+(?:m+)?|ö+h+(?:m+)?)\\b(?:\\s*[,.]+)?\\s*"
    private static let spaceRunPattern = "\\s{2,}"

    private let filler = try! NSRegularExpression(pattern: fillerPattern, options: .caseInsensitive)
    private let spaceRun = try! NSRegularExpression(pattern: spaceRunPattern)

    public init() {}

    public func process(_ text: String) async throws -> String {
        let ns = text as NSString
        let matches = filler.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.upperBound
            out += " "
        }
        out += ns.substring(from: cursor)

        var result = spaceRun.stringByReplacingMatches(
            in: out,
            range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return "" }

        if matches[0].range.location == 0,
           let first = result.first,
           first.isLowercase
        {
            result = String(first).uppercased() + result.dropFirst()
        }
        return result
    }
}
