import Foundation

/// What one polish did, for the log and the CLI harness. Both polishers
/// report this way, so the CLI shows either behind one face. `text` is the
/// only part the coordinator sees.
public struct PolishReport: Sendable {
    public enum Mode: String, Sendable {
        /// The `@Generable` field (`TranscriptPolisher`).
        case guided
        /// Plain `respond(to:)`, after guided generation could not decode.
        case plain
        /// A local model completing the prompt format it was trained on
        /// (`S1MiniPolisher`).
        case completion
    }

    /// Nil when the model could not help; paste the input as it is.
    public var text: String?
    public var elapsed: Duration
    public var wordsIn: Int
    public var wordsOut: Int
    public var chunks: Int
    public var mode: Mode
    /// Why `text` is nil, for the log. Never contains the transcript.
    public var failure: String?
}
