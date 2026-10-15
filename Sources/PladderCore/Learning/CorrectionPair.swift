import Foundation

public struct CorrectionPair: Equatable, Hashable, Sendable, Codable {
    public var heard: String
    public var corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }

    public var key: String {
        heard.lowercased() + "\u{1F}" + corrected.lowercased()
    }
}

public struct CorrectionProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pair: CorrectionPair

    public init(id: UUID = UUID(), pair: CorrectionPair) {
        self.id = id
        self.pair = pair
    }
}
