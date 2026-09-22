import Foundation

/// A word or two the engine wrote, and what the user changed it to by hand
/// after the paste: the raw material of a learned dictionary rule.
public struct CorrectionPair: Equatable, Hashable, Sendable, Codable {
    /// What was pasted, e.g. "Claud". Becomes the rule's `from`.
    public var heard: String
    /// What the user typed over it, e.g. "Claude". Becomes the rule's `to`.
    public var corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }

    /// Case-insensitive identity, for the dismissed set and for duplicate
    /// proposals: "Claud → Claude" and "claud → claude" are the same lesson.
    public var key: String {
        heard.lowercased() + "\u{1F}" + corrected.lowercased()
    }
}

/// A pair the on-device model agreed with, waiting for the user's Add or
/// Dismiss.
public struct CorrectionProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pair: CorrectionPair

    public init(id: UUID = UUID(), pair: CorrectionPair) {
        self.id = id
        self.pair = pair
    }
}
