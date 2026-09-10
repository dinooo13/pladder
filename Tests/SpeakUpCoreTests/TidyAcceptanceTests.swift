import Foundation
import Testing
@testable import SpeakUpCore

@Suite struct TidyAcceptanceTests {
    // MARK: Tokens

    @Test func tokensLowercaseAndStripPunctuation() {
        #expect(TidyAcceptance.tokens("Hello, World! it's 3.5€") == ["hello", "world", "its", "35"])
    }

    @Test func fillerListIsTheAgreedSet() {
        #expect(TidyAcceptance.fillers == [
            "um", "uh", "uhm", "umm", "erm", "er", "hmm", "hm", "mhm", "mm",
            "ah", "äh", "ähm", "öhm", "hmmm",
        ])
    }

    // MARK: Accepted

    @Test func identicalAccepted() {
        #expect(TidyAcceptance.check("hello world", against: "hello world") == nil)
    }

    @Test func punctuationAndCaseOnlyAccepted() {
        #expect(TidyAcceptance.check("Hello, world!", against: "hello world") == nil)
    }

    @Test func fillersAndStuttersRemovedAccepted() {
        #expect(TidyAcceptance.check(
            "So I think we should ship it.",
            against: "um so I I think we should uh ship it") == nil)
    }

    @Test func germanFillersRemovedAccepted() {
        #expect(TidyAcceptance.check(
            "Ich glaube, wir sollten das machen.",
            against: "äh ich glaube wir wir sollten das ähm machen") == nil)
    }

    @Test func repeatedWordCollapsedAccepted() {
        #expect(TidyAcceptance.check("We go.", against: "we we we go") == nil)
    }

    @Test func growsByTwoAccepted() {
        // Two extra words is inside the allowance; punctuation can split a
        // sentence and repeat a subject.
        let original = "alpha bravo charlie delta echo"
        #expect(TidyAcceptance.check("Alpha bravo charlie delta echo delta echo.", against: original) == nil)
    }

    // MARK: Rejected

    @Test func emptyRejected() {
        #expect(TidyAcceptance.check("", against: "hello world") == .empty)
    }

    @Test func whitespaceOnlyRejected() {
        #expect(TidyAcceptance.check("   \n ", against: "hello world") == .empty)
    }

    @Test func tooLongRejected() {
        let original = "hello world"
        let cleaned = String(repeating: "Hello, world! ", count: 4)
        #expect(TidyAcceptance.check(cleaned, against: original) == .tooLong)
    }

    @Test func answeringTheQuestionRejected() {
        // On a very short transcript the length rule fires before the word
        // count one; both mean "the model answered instead of tidying".
        #expect(TidyAcceptance.check(
            "What time is it? It is three o'clock.",
            against: "what time is it") == .tooLong)
        #expect(TidyAcceptance.check(
            "What time is it right now? It is three o'clock.",
            against: "what time is it right now") == .wordCountDrift(expected: 6, actual: 10))
    }

    @Test func growsByThreeRejected() {
        let original = "alpha bravo charlie delta echo"
        #expect(TidyAcceptance.check(
            "Alpha bravo charlie delta echo charlie delta echo.",
            against: original) == .wordCountDrift(expected: 5, actual: 8))
    }

    @Test func rewriteOfEveryWordRejected() {
        let result = TidyAcceptance.check("A dog lay by the rug.", against: "the cat sat on the mat")
        guard case .contentLost(let retained) = result else {
            Issue.record("expected contentLost, got \(String(describing: result))")
            return
        }
        #expect(retained < 0.9)
    }

    @Test func realWordsTreatedAsFillersRejected() {
        // "like", "so", "also", "well" are words, not fillers: dropping them
        // must not be accepted. The count rule catches this one first.
        #expect(TidyAcceptance.check("So.", against: "like so also well")
            == .wordCountDrift(expected: 4, actual: 1))
    }

    @Test func droppingTwoOfFiveWordsIsContentLoss() {
        let original = "alpha bravo charlie delta echo"
        #expect(TidyAcceptance.check("Alpha bravo charlie.", against: original)
            == .contentLost(retained: 0.6))
    }

    @Test func droppingThreeOfFiveWordsIsDrift() {
        let original = "alpha bravo charlie delta echo"
        #expect(TidyAcceptance.check("Alpha bravo.", against: original)
            == .wordCountDrift(expected: 5, actual: 2))
    }

    @Test func longInputToleratesTenPercentLoss() {
        let words = (1...40).map { "word\($0)" }
        let original = words.joined(separator: " ")
        #expect(TidyAcceptance.check(words.dropLast(4).joined(separator: " "), against: original) == nil)
        #expect(TidyAcceptance.check(words.dropLast(5).joined(separator: " "), against: original)
            == .wordCountDrift(expected: 40, actual: 35))
    }

    @Test func allFillersRemovedLeavesNothingRejected() {
        #expect(TidyAcceptance.check("", against: "um uh") == .empty)
    }
}
