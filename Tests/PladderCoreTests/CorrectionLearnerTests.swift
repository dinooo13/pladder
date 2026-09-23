import Foundation
import Testing
@testable import PladderCore

/// Hands out scripted observations, one per call, and records what it was
/// asked to watch.
final class FakePasteObserver: PastedTextObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [PasteObservation?]
    private var _pasted: [String] = []

    init(_ script: [PasteObservation?]) { self.script = script }

    var pasted: [String] { lock.withLock { _pasted } }

    func observe(pasted: String) async -> PasteObservation? {
        lock.withLock {
            _pasted.append(pasted)
            return script.isEmpty ? nil : script.removeFirst()
        }
    }
}

/// Answers per pair, yes by default, and records every question.
final class FakeCorrectionReviewer: CorrectionReviewer, @unchecked Sendable {
    struct Failure: Error {}

    let isAvailable: Bool
    private let lock = NSLock()
    private let verdicts: [String: Bool]
    private let failing: Set<String>
    private var _calls: [(heard: String, corrected: String, sentence: String)] = []

    init(available: Bool = true, verdicts: [String: Bool] = [:], failing: Set<String> = []) {
        isAvailable = available
        self.verdicts = verdicts
        self.failing = failing
    }

    var calls: [(heard: String, corrected: String, sentence: String)] { lock.withLock { _calls } }

    func isReusableCorrection(heard: String, corrected: String, sentence: String) async throws -> Bool {
        lock.withLock { _calls.append((heard, corrected, sentence)) }
        if failing.contains(heard) { throw Failure() }
        return verdicts[heard] ?? true
    }
}

final class ProposalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _pairs: [CorrectionPair] = []
    var pairs: [CorrectionPair] { lock.withLock { _pairs } }
    func append(_ proposal: CorrectionProposal) { lock.withLock { _pairs.append(proposal.pair) } }
}

@Suite struct CorrectionLearnerTests {
    private static func temporaryDismissed() -> DismissedCorrections {
        DismissedCorrections(url: FileManager.default.temporaryDirectory
            .appending(path: "pladder-tests-\(UUID().uuidString)/dismissed-corrections.json"))
    }

    private static func observation(_ pasted: String, _ final: String) -> PasteObservation {
        PasteObservation(pasted: pasted, readings: [final])
    }

    private static func learner(
        observer: FakePasteObserver,
        reviewer: FakeCorrectionReviewer,
        dismissed: DismissedCorrections = temporaryDismissed(),
        dictionary: [DictionaryEntry] = [],
        proposals: ProposalLog
    ) -> CorrectionLearner {
        CorrectionLearner(
            observer: observer, reviewer: reviewer, dismissed: dismissed,
            dictionary: { dictionary },
            onProposal: { proposals.append($0) })
    }

    private let claud = CorrectionPair(heard: "Claud", corrected: "Claude")

    @Test func proposesAPairTheReviewerAccepts() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: FakeCorrectionReviewer(), proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted == ["I tried Claud today"])
        #expect(proposals.pairs == [claud])
    }

    @Test func dropsAPairTheReviewerRejects() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer(verdicts: ["Claud": false])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(reviewer.calls.count == 1)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func theGateRunsBeforeTheReviewer() async {
        let observer = FakePasteObserver([Self.observation("see you on Friday then", "see you on Monday then")])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("see you on Friday then").value
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func aDismissedPairIsNotProposedAgain() async {
        let dismissed = Self.temporaryDismissed()
        await dismissed.dismiss(CorrectionPair(heard: "claud", corrected: "claude"))
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, dismissed: dismissed, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func aPairAlreadyInTheDictionaryIsNotProposed() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(
            observer: observer, reviewer: reviewer,
            dictionary: [DictionaryEntry(from: "claud ", to: "Claudia")], proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func nothingHappensWhenTheObserverReturnsNil() async {
        let observer = FakePasteObserver([nil])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted.count == 1)
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func nothingHappensWhenTheModelIsUnavailable() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer(available: false)
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted.isEmpty)
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.pairs.isEmpty)
    }

    @Test func aReviewerErrorDropsOnlyThatCandidate() async {
        let observer = FakePasteObserver([Self.observation(
            "Claud and get hub and the rest of it stays", "Claude and GitHub and the rest of it stays")])
        let reviewer = FakeCorrectionReviewer(failing: ["Claud"])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("Claud and get hub and the rest of it stays").value
        #expect(reviewer.calls.count == 2)
        #expect(proposals.pairs == [CorrectionPair(heard: "get hub", corrected: "GitHub")])
    }

    @Test func twoPastesAreObservedAndReviewedIndependently() async {
        let observer = FakePasteObserver([
            Self.observation("I tried Claud today", "I tried Claude today"),
            Self.observation("push it to get hub now", "push it to GitHub now"),
        ])
        let proposals = ProposalLog()
        let learner = Self.learner(observer: observer, reviewer: FakeCorrectionReviewer(), proposals: proposals)
        let first = learner.pasted("I tried Claud today")
        let second = learner.pasted("push it to get hub now")
        await first.value
        await second.value
        #expect(observer.pasted.count == 2)
        #expect(Set(proposals.pairs) == [claud, CorrectionPair(heard: "get hub", corrected: "GitHub")])
    }

    @Test func atMostThreeProposalsPerPaste() async {
        // Three hunks is the diff's own limit, so the cap is reached exactly;
        // a fourth would make the diff call it a rewrite.
        let pasted = "Claud and get hub and kubernetties are all words in this longer sentence here"
        let final = "Claude and GitHub and Kubernetes are all words in this longer sentence here"
        let observer = FakePasteObserver([Self.observation(pasted, final)])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals).pasted(pasted).value
        #expect(proposals.pairs.count == CorrectionLearner.maximumProposalsPerPaste)
    }

    @Test func theReviewerSeesTheSentence() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today ", "I tried Claude today ")])
        let reviewer = FakeCorrectionReviewer()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: ProposalLog())
            .pasted("I tried Claud today").value
        #expect(reviewer.calls.first?.sentence == "I tried Claud today")
        #expect(reviewer.calls.first?.heard == "Claud")
        #expect(reviewer.calls.first?.corrected == "Claude")
    }

    @Test func aLongPasteIsCutAroundThePair() {
        let pasted = String(repeating: "word ", count: 200) + "Claud" + String(repeating: " word", count: 200)
        let sentence = CorrectionLearner.sentence(around: "Claud", in: pasted)
        #expect(sentence.count == CorrectionLearner.sentenceLimit)
        #expect(sentence.contains("Claud"))
    }
}
