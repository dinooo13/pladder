import Foundation

public protocol CorrectionReviewer: Sendable {
    var isAvailable: Bool { get }

    func isReusableCorrection(heard: String, corrected: String, sentence: String) async throws -> Bool
}
