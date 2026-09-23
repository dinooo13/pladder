import Foundation

/// Judges a correction the diff and the phonetic gate let through.
/// Implemented with Apple's on-device model in `PladderRefine`; tests use a
/// fake.
public protocol CorrectionReviewer: Sendable {
    /// False when the on-device model cannot be used; the feature is then
    /// absent. Cheap, read on every paste.
    var isAvailable: Bool { get }

    /// Yes when `corrected` is the same word or name as `heard`, spelled the
    /// way the user wants, so a dictionary rule heard → corrected would be
    /// right every time. No for a rewording, a different word, a change of
    /// meaning. `sentence` is the pasted text around the pair, for context.
    func isReusableCorrection(heard: String, corrected: String, sentence: String) async throws -> Bool
}
