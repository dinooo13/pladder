import Foundation

extension String {
    // One count for the coordinator's minimum to polish and the polishers' chunks.
    public var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
}
