import Foundation
import Testing
@testable import PladderRefine

// Nothing here calls the model: these run on a Mac without Apple
// Intelligence and keep `swift test` well under a second.

@Suite struct PolishPostFilterTests {
    @Test func stripsALeadingThinkBlock() {
        #expect(PolishPostFilter.clean("<think>the user wants a list</think>\n\nSend it Friday.") == "Send it Friday.")
    }

    @Test func stripsAThinkingBlockCaseInsensitively() {
        #expect(PolishPostFilter.clean("  <THINKING>hm\nok</Thinking> Send it Friday.") == "Send it Friday.")
    }

    @Test func keepsAThinkTagInTheMiddleOfTheText() {
        let text = "Wrap it in <think> and </think> tags."
        #expect(PolishPostFilter.clean(text) == text)
    }

    @Test func removesInvisibleCharacters() {
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] {
            #expect(PolishPostFilter.clean("\(scalar)Send\(scalar) it Friday.\(scalar)") == "Send it Friday.")
        }
    }

    @Test func trimsSurroundingWhitespaceAndNewlines() {
        #expect(PolishPostFilter.clean("\n\n  Send it Friday. \n") == "Send it Friday.")
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "First paragraph.\n\n- one\n- two"
        #expect(PolishPostFilter.clean(text) == text)
    }
}

@Suite struct TranscriptPolisherTests {
    @Test func aShortTranscriptIsOneChunk() {
        let text = "send it on Friday. and copy Anna."
        #expect(TranscriptPolisher.chunks(of: text) == [text])
    }

    @Test func aLongTranscriptIsCutAtSentenceEnds() {
        // 700 words in sentences of seven.
        let sentence = "one two three four five six seven."
        let text = Array(repeating: sentence, count: 100).joined(separator: " ")
        let chunks = TranscriptPolisher.chunks(of: text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func thePromptFramesTheTranscriptAndNamesItsLanguage() {
        let english = "can you send me the slides before the meeting tomorrow"
        #expect(TranscriptPolisher.prompt(for: english) == "Transcript, in English:\n\"\"\"\n\(english)\n\"\"\"")
        let german = "ich schicke dir die präsentation morgen vor dem termin"
        #expect(TranscriptPolisher.prompt(for: german).hasPrefix("Transcript, in German:\n"))
    }

    @Test func noLanguageIsNamedWhenTheRecogniserIsUnsure() {
        #expect(TranscriptPolisher.prompt(for: "42") == "Transcript:\n\"\"\"\n42\n\"\"\"")
    }
}
