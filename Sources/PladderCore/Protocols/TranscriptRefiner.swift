import Foundation

public protocol TranscriptRefiner: Sendable {
    func prepare() async
    // Nil means "paste what came in". Never throws: a cleanup step must not lose a dictation.
    func refine(_ text: String) async -> String?
}
