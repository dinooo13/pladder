import Foundation

/// One utterance a streaming engine has begun: the handle every later call
/// for it names. The engine mints it, so two recordings can never share one.
public struct Utterance: Hashable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// An engine that consumes audio while it is being recorded, so that only
/// the tail remains to transcribe at release.
///
/// Every call after `beginUtterance` names the utterance it is for, and a
/// call naming one that is no longer the engine's current utterance does
/// nothing: a feed or an abandon from a recording that was cancelled cannot
/// reach the one that started after it, whichever order they arrive in.
public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    /// Starts an empty utterance and returns its handle. The previous one, if
    /// any, is cancelled first. Throws if another `beginUtterance` or an
    /// abandon of this one overtook it while it began.
    func beginUtterance() async throws -> Utterance
    /// 16 kHz mono samples captured since the previous call.
    func feed(_ samples: [Float], to utterance: Utterance) async
    /// Feeds the last samples and returns the transcript for the whole
    /// utterance. Throws `TranscriptionError.notLoaded` for an utterance that
    /// is not the current one.
    func endUtterance(_ utterance: Utterance, tail: [Float]) async throws -> Transcript
    /// Stop feeding and drop whatever was fed this utterance.
    func abandonUtterance(_ utterance: Utterance) async
    /// Brings the engine's compute up to speed while the user is still
    /// speaking, before the first real work arrives. Fire and forget.
    func warmPass() async
    /// A pass over the audio fed to `utterance` so far, for display only. It
    /// costs what `warmPass` costs — the same padded window through the same
    /// call — so an engine answering this is warmed by it, and the
    /// coordinator runs one loop or the other, never both.
    ///
    /// The text is what a release right now would produce, never what the
    /// release will produce, and it never reaches the output. Nil when there
    /// is nothing to show.
    func livePass(_ utterance: Utterance) async -> String?
}

extension StreamingTranscriptionEngine {
    public func warmPass() async {}

    /// An engine with no live pass still has to be kept warm, so the default
    /// does the job the warm loop would have done and shows nothing.
    public func livePass(_ utterance: Utterance) async -> String? {
        await warmPass()
        return nil
    }
}
