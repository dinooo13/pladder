import Foundation

public struct ShortSentence: Sendable, Equatable {
    public static let maximumWords = 10

    public var dropPeriod: Bool
    public var dropCapital: Bool

    public init(dropPeriod: Bool, dropCapital: Bool) {
        self.dropPeriod = dropPeriod
        self.dropCapital = dropCapital
    }

    // One sentence only: in "Yes. Do it." the first stop would be left dangling. An
    // ellipsis or an abbreviation such as "z.B." keeps its stop; "I" and a word with a
    // capital inside, such as "API", keep their capital.
    public func apply(_ text: String) -> String {
        guard dropPeriod || dropCapital else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, let last = words.last, words.count <= Self.maximumWords,
              !words.dropLast().contains(where: { $0.last.map(".?!".contains) ?? false })
        else { return text }
        var result = text
        if dropPeriod, text.hasSuffix("."), last.count > 1, !last.hasSuffix(".."),
           !Self.isAbbreviation(last.dropLast()) {
            result.removeLast()
        }
        if dropCapital, first.first?.isUppercase == true, !first.dropFirst().contains(where: \.isUppercase),
           !Self.isPronounI(first) {
            result = result.prefix(1).lowercased() + result.dropFirst()
        }
        return result
    }

    private static func isAbbreviation(_ word: Substring) -> Bool {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { $0.count <= 2 }
    }

    private static func isPronounI(_ word: Substring) -> Bool {
        let bare = word.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        return bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’")
    }
}
