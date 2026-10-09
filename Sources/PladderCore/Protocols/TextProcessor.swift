import Foundation

/// A post-processing step applied to transcribed text before it is inserted.
///
/// Synchronous and unable to fail: a processor runs on every dictation,
/// between the engine and the paste, so it is plain string work, and one
/// that cannot do its job returns the text it was given. Anything slow, such
/// as a language model, is a `TranscriptRefiner` instead. A processor holds
/// no user-facing text: the app words it by `id`.
public protocol TextProcessor: Sendable {
    /// Stable identifier, used for the enable/disable toggles in settings and
    /// for the processor's name in the app.
    var id: String { get }

    func process(_ text: String) -> String
}
