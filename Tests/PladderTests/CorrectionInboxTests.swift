import Foundation
import PladderCore
import PladderTestSupport
import Testing
@testable import Pladder

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CorrectionInboxTests {
    private let claud = CorrectionPair(heard: "Claud", corrected: "Claude")
    private let jemini = CorrectionPair(heard: "Jemini", corrected: "Gemini")
    private let pythen = CorrectionPair(heard: "Pythen", corrected: "Python")
    private let kotlen = CorrectionPair(heard: "Kotlen", corrected: "Kotlin")

    private func inbox(
        pasting observations: [PasteObservation], reviewer: FakeCorrectionReviewer = FakeCorrectionReviewer()
    ) throws -> (CorrectionInbox, URL) {
        let dismissedURL = try scratchDirectory("pladder-inbox").appending(path: "dismissed-corrections.json")
        let inbox = CorrectionInbox(
            dismissedURL: dismissedURL, observer: FakePasteObserver(observations), reviewer: reviewer)
        return (inbox, dismissedURL)
    }

    private static func observation(_ pasted: String, _ final: String) -> PasteObservation {
        PasteObservation(pasted: pasted, readings: [final])
    }

    private static let claudPaste = observation("I tried Claud today", "I tried Claude today")
    private static let claudAndJeminiPaste = observation(
        "Claud and Jemini are models", "Claude and Gemini are models")
    private static let pythenAndKotlenPaste = observation(
        "Pythen and Kotlen are languages", "Python and Kotlin are languages")

    @Test func aCorrectionTheReviewerAcceptsIsProposed() async throws {
        let (inbox, _) = try inbox(pasting: [Self.claudPaste])
        inbox.pasted(Self.claudPaste.pasted)
        #expect(await waitUntil { inbox.proposals.map(\.pair) == [claud] })
    }

    @Test func acceptingAddsTheRuleAndDropsTheProposal() async throws {
        let (inbox, _) = try inbox(pasting: [Self.claudPaste])
        var added: [[DictionaryEntry]] = []
        inbox.addRules = { added.append($0) }
        inbox.pasted(Self.claudPaste.pasted)
        #expect(await waitUntil { inbox.proposals.count == 1 })
        inbox.accept(inbox.proposals[0])
        #expect(inbox.proposals.isEmpty)
        #expect(added.map { $0.map { [$0.from, $0.to] } } == [[["Claud", "Claude"]]])
    }

    @Test func dismissingDropsTheProposalAndRemembersThePair() async throws {
        let (inbox, dismissedURL) = try inbox(pasting: [Self.claudPaste])
        inbox.pasted(Self.claudPaste.pasted)
        #expect(await waitUntil { inbox.proposals.count == 1 })
        inbox.dismiss(inbox.proposals[0])
        #expect(inbox.proposals.isEmpty)
        let claud = claud
        #expect(await eventually { await DismissedCorrections(url: dismissedURL).contains(claud) })
    }

    @Test func aPairAlreadyProposedIsNotProposedAgain() async throws {
        let (inbox, _) = try inbox(pasting: [Self.claudPaste, Self.claudAndJeminiPaste])
        inbox.pasted(Self.claudPaste.pasted)
        #expect(await waitUntil { inbox.proposals.count == 1 })
        inbox.pasted(Self.claudAndJeminiPaste.pasted)
        #expect(await waitUntil { inbox.proposals.contains { $0.pair == jemini } })
        #expect(inbox.proposals.map(\.pair) == [jemini, claud])
    }

    @Test func theNewestThreeProposalsAreKept() async throws {
        let (inbox, _) = try inbox(pasting: [Self.claudAndJeminiPaste, Self.pythenAndKotlenPaste])
        inbox.pasted(Self.claudAndJeminiPaste.pasted)
        #expect(await waitUntil { inbox.proposals.count == 2 })
        inbox.pasted(Self.pythenAndKotlenPaste.pasted)
        #expect(await waitUntil { inbox.proposals.contains { $0.pair == kotlen } })
        #expect(inbox.proposals.map(\.pair) == [kotlen, pythen, jemini])
    }

    @Test func aRuleAddedWhileTheReviewWaitedDropsItsProposal() async throws {
        let (inbox, _) = try inbox(pasting: [Self.claudAndJeminiPaste])
        let quiet = Gate()
        var rules: [DictionaryEntry] = []
        inbox.dictionary = { rules }
        inbox.waitUntilQuiet = { await quiet.wait() }
        inbox.pasted(Self.claudAndJeminiPaste.pasted)
        #expect(await eventually { await quiet.arrivals == 1 })
        rules = [DictionaryEntry(from: "Claud", to: "Claude")]
        await quiet.open()
        #expect(await waitUntil { inbox.proposals.contains { $0.pair == jemini } })
        #expect(inbox.proposals.map(\.pair) == [jemini])
    }
}
