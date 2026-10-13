import Foundation

extension String {
    /// Words split at any whitespace: one count for the coordinator's
    /// minimum to polish and the polishers' chunks, so the two cannot drift.
    public var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
}
