import Foundation

public struct WhitespaceNormalizer: TextProcessor {
    public static let processorID = "whitespace"

    public let id = WhitespaceNormalizer.processorID

    public init() {}

    public func process(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
