import Foundation
import Testing
@testable import PladderRefine

@Suite struct PolishChunkingTests {
    private func unpunctuated(_ count: Int) -> String {
        (1...count).map { "word\($0)" }.joined(separator: " ")
    }

    @Test func aLongTranscriptWithoutSentenceEndsIsCutBetweenWords() {
        let text = unpunctuated(1_000)
        for (threshold, size) in [
            (S1MiniPolisher.chunkThreshold, S1MiniPolisher.chunkSize),
            (TranscriptPolisher.chunkThreshold, TranscriptPolisher.chunkSize),
        ] {
            let chunks = PolishChunking.chunks(of: text, threshold: threshold, size: size)
            #expect(chunks.count > 1)
            #expect(chunks.allSatisfy { PolishChunking.wordCount($0) <= size * 3 / 2 })
            #expect(chunks.joined(separator: " ") == text)
        }
    }

    @Test func aSentenceEndBeforeTheHardLimitStillDecidesTheCut() {
        let sentence = Array(repeating: "word", count: 299).joined(separator: " ") + " end."
        let text = Array(repeating: sentence, count: 3).joined(separator: " ")
        let chunks = PolishChunking.chunks(
            of: text, threshold: S1MiniPolisher.chunkThreshold, size: S1MiniPolisher.chunkSize)
        #expect(chunks == [sentence, sentence, sentence])
    }

    @Test func aShortTranscriptIsNeverCut() {
        let text = unpunctuated(S1MiniPolisher.chunkThreshold)
        #expect(PolishChunking.chunks(
            of: text, threshold: S1MiniPolisher.chunkThreshold, size: S1MiniPolisher.chunkSize) == [text])
    }
}
