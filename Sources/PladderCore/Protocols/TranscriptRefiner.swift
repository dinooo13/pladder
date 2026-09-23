import Foundation

/// A second pass over the processed transcript by something slow, such as an
/// on-device language model. Runs only for a dictation started with the
/// polish toggle; when it is off the coordinator never calls it.
public protocol TranscriptRefiner: Sendable {
    /// Called at key-down of a polished dictation, while the user is still
    /// speaking, so the model's load is off the release path. Fire and forget.
    func prepare() async
    /// The polished text, or nil when the model could not help (unavailable,
    /// refused, timed out, empty answer). Nil means "paste what came in".
    /// Never throws: a cleanup step must not lose a dictation.
    func refine(_ text: String) async -> String?
}
