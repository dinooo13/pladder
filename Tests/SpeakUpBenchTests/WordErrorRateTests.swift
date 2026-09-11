import Testing
@testable import SpeakUpBench

@Suite struct WordErrorRateTests {
    @Test func identicalTextIsZero() {
        #expect(WordErrorRate.compute(reference: "hello world", hypothesis: "hello world") == 0)
    }

    @Test func punctuationAndCaseAreIgnored() {
        #expect(WordErrorRate.compute(reference: "Hello, world! It's fine.", hypothesis: "hello world its fine") == 0)
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        // one substitution (cat -> hat), one deletion (the), one insertion (big)
        let wer = WordErrorRate.compute(reference: "the cat sat on the mat", hypothesis: "hat sat on the big mat")
        #expect(abs(wer - 3.0 / 6.0) < 1e-9)
    }

    @Test func emptyHypothesisIsAllDeletions() {
        #expect(WordErrorRate.compute(reference: "one two three", hypothesis: "") == 1)
    }

    @Test func emptyReferenceCountsInsertions() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "a b") == 2)
    }

    @Test func normalizeSplitsOnHyphensAndWhitespace() {
        #expect(WordErrorRate.normalize("push-to-talk  dictation\n now") == ["push", "to", "talk", "dictation", "now"])
    }
}
