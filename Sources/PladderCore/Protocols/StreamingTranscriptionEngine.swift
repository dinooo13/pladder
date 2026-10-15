import Foundation

public struct Utterance: Hashable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

// A call naming an utterance that is no longer the current one does nothing; see
// docs/ARCHITECTURE.md, "Engine".
public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    // Replaces any utterance in progress; throws if another begin, or an abandon of
    // this one, overtook it while it began.
    func beginUtterance() async throws -> Utterance
    func feed(_ samples: [Float], to utterance: Utterance) async
    func endUtterance(_ utterance: Utterance, tail: [Float]) async throws -> Transcript
    func abandonUtterance(_ utterance: Utterance) async
    func warmPass() async
    func livePass(_ utterance: Utterance) async -> String?
}

extension StreamingTranscriptionEngine {
    public func warmPass() async {}

    // An engine with no live pass still has to be kept warm.
    public func livePass(_ utterance: Utterance) async -> String? {
        await warmPass()
        return nil
    }
}
