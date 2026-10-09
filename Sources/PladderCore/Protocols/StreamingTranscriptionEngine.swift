import Foundation

public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    // Replaces any utterance in progress.
    func beginUtterance() async throws
    func feed(_ samples: [Float]) async
    func endUtterance(_ tail: [Float]) async throws -> Transcript
    func abandonUtterance() async
    func warmPass() async
    func livePass() async -> String?
}

extension StreamingTranscriptionEngine {
    public func warmPass() async {}

    // An engine with no live pass still has to be kept warm.
    public func livePass() async -> String? {
        await warmPass()
        return nil
    }
}
