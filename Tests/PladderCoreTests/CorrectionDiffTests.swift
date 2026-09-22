import Foundation
import Testing
@testable import PladderCore

@Suite struct CorrectionDiffTests {
    private func pair(_ heard: String, _ corrected: String) -> CorrectionPair {
        CorrectionPair(heard: heard, corrected: corrected)
    }

    @Test func oneWordSubstitution() {
        #expect(CorrectionDiff.candidates(pasted: "I tried Claud today", final: "I tried Claude today")
            == [pair("Claud", "Claude")])
    }

    @Test func twoWordPhraseToOneWord() {
        #expect(CorrectionDiff.candidates(pasted: "push it to get hub now", final: "push it to GitHub now")
            == [pair("get hub", "GitHub")])
    }

    @Test func oneWordToTwoWords() {
        #expect(CorrectionDiff.candidates(pasted: "open clodecode please", final: "open Claude Code please")
            == [pair("clodecode", "Claude Code")])
    }

    @Test func punctuationIsABoundary() {
        #expect(CorrectionDiff.candidates(pasted: "ask Claud, then run it", final: "ask Claude, then run it")
            == [pair("Claud", "Claude")])
        #expect(CorrectionDiff.candidates(pasted: "I like Claud.", final: "I like Claude.")
            == [pair("Claud", "Claude")])
    }

    @Test func aHunkThatChangesPunctuationIsDropped() {
        #expect(CorrectionDiff.candidates(pasted: "ask Claud, then run it", final: "ask Claude; then run it") == [])
    }

    @Test func apostrophesAndHyphensStayInsideAWord() {
        let words = CorrectionDiff.tokens("don't e-mail it’s -x").map(\.text)
        #expect(words == ["don't", "e-mail", "it’s", "-", "x"])
        #expect(CorrectionDiff.candidates(pasted: "I dont know yet", final: "I don't know yet")
            == [pair("dont", "don't")])
    }

    @Test func pureCaseChangeIsIgnored() {
        #expect(CorrectionDiff.candidates(pasted: "ask claude now", final: "ask Claude now") == [])
    }

    @Test func insertionsAndDeletionsAreIgnored() {
        #expect(CorrectionDiff.candidates(pasted: "send it now please", final: "send it right now please") == [])
        #expect(CorrectionDiff.candidates(pasted: "send it right now please", final: "send it now please") == [])
    }

    @Test func threeWordSpansAreNotCandidates() {
        #expect(CorrectionDiff.candidates(
            pasted: "we met near the big red house today",
            final: "we met near one small blue house today") == [])
    }

    @Test func aRewriteYieldsNothing() {
        // Four separate changes: a rewrite, not three corrections and a spare.
        #expect(CorrectionDiff.candidates(
            pasted: "one two three four five six seven eight nine ten",
            final: "one to three for five sicks seven ate nine ten") == [])
        // More than half the words changed.
        #expect(CorrectionDiff.candidates(
            pasted: "the quick brown fox jumps",
            final: "a slow brown cat sleeps") == [])
    }

    @Test func marginTextAroundThePasteIsIgnored() {
        let observation = PasteObservation(
            before: "Dear Bob, ", pasted: "I tried Claud today ", after: "Best",
            readings: ["Dear Rob, I tried Claude today Best"])
        #expect(CorrectionDiff.candidates(in: observation) == [pair("Claud", "Claude")])
    }

    @Test func aChangeReachingIntoTheMarginIsIgnored() {
        let observation = PasteObservation(
            before: "Hello ", pasted: "Claud ", after: "",
            readings: ["Hi Claude "])
        #expect(CorrectionDiff.candidates(in: observation) == [])
    }

    @Test func aOneWordPasteIsAnchoredByItsMargin() {
        let observation = PasteObservation(
            before: "Thanks for the tip. ", pasted: "Claud ", after: "",
            readings: ["Thanks for the tip. Claude "])
        #expect(CorrectionDiff.candidates(in: observation) == [pair("Claud", "Claude")])
    }

    @Test func aOneWordPasteIntoAnEmptyFieldCanBeCorrected() {
        #expect(CorrectionDiff.candidates(pasted: "Claud", final: "Claude") == [pair("Claud", "Claude")])
    }

    @Test func longTokensAreRejected() {
        let long = String(repeating: "a", count: 300)
        #expect(CorrectionDiff.candidates(pasted: "say \(long) now", final: "say \(long)b now") == [])
    }

    @Test func controlCharactersAreRejected() {
        #expect(CorrectionDiff.candidates(pasted: "say Claud now", final: "say Cla\u{7}ude now") == [])
    }

    @Test func theLastReadingThatStillHoldsThePasteIsUsed() {
        // The user fixed the word and pressed Return; the chat field emptied.
        let observation = PasteObservation(
            pasted: "I tried Claud today", readings: ["I tried Claud today", "I tried Claude today", ""])
        #expect(CorrectionDiff.candidates(in: observation) == [pair("Claud", "Claude")])
    }

    @Test func aReadingWithoutTheAnchorIsSkipped() {
        let observation = PasteObservation(
            pasted: "I tried Claud today",
            readings: ["I tried Claude today", "something else entirely different"])
        #expect(CorrectionDiff.candidates(in: observation) == [pair("Claud", "Claude")])
    }

    @Test func theLastAnchoredReadingWinsEvenWhenItUndoesTheFix() {
        let observation = PasteObservation(
            pasted: "I tried Claud today", readings: ["I tried Claude today", "I tried Claud today"])
        #expect(CorrectionDiff.candidates(in: observation) == [])
    }

    @Test func noReadingsGiveNothing() {
        #expect(CorrectionDiff.candidates(in: PasteObservation(pasted: "I tried Claud today", readings: [])) == [])
    }

    @Test func anUnchangedFieldGivesNothing() {
        #expect(CorrectionDiff.candidates(pasted: "I tried Claud today", final: "I tried Claud today") == [])
    }

    @Test func theTrailingSpaceVariantDiffsTheSame() {
        #expect(CorrectionDiff.candidates(pasted: "I tried Claud today ", final: "I tried Claude today ")
            == [pair("Claud", "Claude")])
    }

    @Test func pairsComeInTextOrder() {
        #expect(CorrectionDiff.candidates(
            pasted: "Claud and get hub and the rest of it stays",
            final: "Claude and GitHub and the rest of it stays")
            == [pair("Claud", "Claude"), pair("get hub", "GitHub")])
    }
}
