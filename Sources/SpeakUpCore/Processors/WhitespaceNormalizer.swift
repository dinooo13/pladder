import Foundation

/// Trims the transcript and collapses internal runs of whitespace.
public struct WhitespaceNormalizer: TextProcessor {
    public static let processorID = "whitespace"

    public let id = WhitespaceNormalizer.processorID
    public let displayName = "Tidy whitespace"

    public init() {}

    public func process(_ text: String) async throws -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
