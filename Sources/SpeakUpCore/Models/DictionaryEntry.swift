import Foundation

/// One user dictionary rule: replace `from` with `to`.
public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// The spoken form as the engine tends to transcribe it, e.g. "claude code".
    public var from: String
    /// The replacement, e.g. "Claude Code".
    public var to: String
    /// When true, `from` must match exactly including case. Default is
    /// case-insensitive with capitalisation carried over at sentence start.
    public var matchCase: Bool

    public init(id: UUID = UUID(), from: String, to: String, matchCase: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.matchCase = matchCase
    }
}
