import Foundation

/// An engine that consumes audio while it is being recorded, so that only
/// the tail remains to transcribe at release.
public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    /// Start an empty utterance. Cancel any previous one first.
    func beginUtterance() async throws
    /// 16 kHz mono samples captured since the previous call.
    func feed(_ samples: [Float]) async
    /// Feeds the last samples and returns the transcript for the whole utterance.
    func endUtterance(_ tail: [Float]) async throws -> Transcript
    /// Stop feeding and drop whatever was fed this utterance.
    func abandonUtterance() async
    /// Brings the engine's compute up to speed while the user is still
    /// speaking, before the first real work arrives. Fire and forget.
    func warmPass() async
}

extension StreamingTranscriptionEngine {
    public func warmPass() async {}
}
