import Foundation
import PladderTestSupport
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
    private let failure: any Error
    private var _calls: [(heard: String, corrected: String, sentence: String)] = []

    init(
        available: Bool = true, verdicts: [String: Bool] = [:], failing: Set<String> = [],
        failure: any Error = Failure()
    ) {
        isAvailable = available
        self.verdicts = verdicts
        self.failing = failing
        self.failure = failure
    }

    var calls: [(heard: String, corrected: String, sentence: String)] { lock.withLock { _calls } }

    func isReusableCorrection(heard: String, corrected: String, sentence: String) async throws -> Bool {
        lock.withLock { _calls.append((heard, corrected, sentence)) }
        if failing.contains(heard) { throw failure }
        return verdicts[heard] ?? true
    }
}

typealias ProposalLog = Recorder<CorrectionPair>

@Suite(.timeLimit(.minutes(1))) struct CorrectionLearnerTests {
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
        log: @escaping @Sendable (String) -> Void = { _ in },
        waitUntilQuiet: @escaping @Sendable () async -> Void = {},
        proposals: ProposalLog
    ) -> CorrectionLearner {
        CorrectionLearner(
            observer: observer, reviewer: reviewer, dismissed: dismissed,
            dictionary: { dictionary },
            log: log,
            waitUntilQuiet: waitUntilQuiet,
            onProposal: { proposals.append($0.pair) })
    }

    private let claud = CorrectionPair(heard: "Claud", corrected: "Claude")

    @Test func proposesAPairTheReviewerAccepts() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: FakeCorrectionReviewer(), proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted == ["I tried Claud today"])
        #expect(proposals.all == [claud])
    }

    @Test func dropsAPairTheReviewerRejects() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer(verdicts: ["Claud": false])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(reviewer.calls.count == 1)
        #expect(proposals.all.isEmpty)
    }

    @Test func theGateRunsBeforeTheReviewer() async {
        let observer = FakePasteObserver([Self.observation("see you on Friday then", "see you on Monday then")])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("see you on Friday then").value
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.all.isEmpty)
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
        #expect(proposals.all.isEmpty)
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
        #expect(proposals.all.isEmpty)
    }

    @Test func nothingHappensWhenTheObserverReturnsNil() async {
        let observer = FakePasteObserver([nil])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted.count == 1)
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.all.isEmpty)
    }

    @Test func nothingHappensWhenTheModelIsUnavailable() async {
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer(available: false)
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("I tried Claud today").value
        #expect(observer.pasted.isEmpty)
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.all.isEmpty)
    }

    @Test func aReviewerErrorDropsOnlyThatCandidate() async {
        let observer = FakePasteObserver([Self.observation(
            "Claud and get hub and the rest of it stays", "Claude and GitHub and the rest of it stays")])
        let reviewer = FakeCorrectionReviewer(failing: ["Claud"])
        let proposals = ProposalLog()
        await Self.learner(observer: observer, reviewer: reviewer, proposals: proposals)
            .pasted("Claud and get hub and the rest of it stays").value
        #expect(reviewer.calls.count == 2)
        #expect(proposals.all == [CorrectionPair(heard: "get hub", corrected: "GitHub")])
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
        #expect(Set(proposals.all) == [claud, CorrectionPair(heard: "get hub", corrected: "GitHub")])
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
        #expect(proposals.all.count == CorrectionLearner.maximumProposalsPerPaste)
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

    /// A recording or a polished dictation is in flight: the review waits
    /// for the model to be free rather than eat into the polish budget.
    @Test func theReviewWaitsUntilTheGateOpens() async {
        let gate = Gate()
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer()
        let proposals = ProposalLog()
        let task = Self.learner(
            observer: observer, reviewer: reviewer, waitUntilQuiet: { await gate.pass() }, proposals: proposals)
            .pasted("I tried Claud today")

        await gate.untilSomeoneWaits()
        #expect(reviewer.calls.isEmpty)
        #expect(proposals.all.isEmpty)

        await gate.open()
        await task.value
        #expect(reviewer.calls.count == 1)
        #expect(proposals.all == [claud])
    }

    @Test func theGateIsNotAskedWhenNothingIsReviewed() async {
        let gate = Gate()
        let observer = FakePasteObserver([Self.observation("see you on Friday then", "see you on Monday then")])
        await Self.learner(
            observer: observer, reviewer: FakeCorrectionReviewer(), waitUntilQuiet: { await gate.pass() },
            proposals: ProposalLog())
            .pasted("see you on Friday then").value
        #expect(await gate.arrivals == 0)
    }

    /// A model error can quote the prompt, which is the user's words.
    @Test func aReviewerErrorIsLoggedByCaseNotByText() async {
        enum ModelError: Error { case generation(String) }
        let observer = FakePasteObserver([Self.observation("I tried Claud today", "I tried Claude today")])
        let reviewer = FakeCorrectionReviewer(
            failing: ["Claud"], failure: ModelError.generation("HEARD: Claud SENTENCE: I tried Claud today"))
        let lines = Recorder<String>()
        await Self.learner(observer: observer, reviewer: reviewer, log: { lines.append($0) }, proposals: ProposalLog())
            .pasted("I tried Claud today").value
        let failed = lines.all.first { $0.hasPrefix("review failed") }
        #expect(failed?.hasSuffix(": ModelError.generation") == true)
        #expect(failed?.contains("SENTENCE") == false)
    }

    @Test func errorsAreDescribedByTypeAndCase() {
        enum Plain: Error { case timedOut }
        struct Opaque: Error { let words = "secret" }
        #expect(CorrectionLearner.describe(Plain.timedOut) == "Plain.timedOut")
        #expect(CorrectionLearner.describe(Opaque()) == "Opaque")
        let ns = NSError(domain: "FM", code: 7, userInfo: [NSLocalizedDescriptionKey: "secret"])
        #expect(CorrectionLearner.describe(ns) == "NSError FM 7")
    }

    @Test func aLongPasteIsCutAroundThePair() {
        let pasted = String(repeating: "word ", count: 200) + "Claud" + String(repeating: " word", count: 200)
        let sentence = CorrectionLearner.sentence(around: "Claud", in: pasted)
        #expect(sentence.count == CorrectionLearner.sentenceLimit)
        #expect(sentence.contains("Claud"))
    }
}

/// Holds everyone who passes until it is opened, and counts them.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        for watcher in watchers { watcher.resume() }
        watchers = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    /// Returns once somebody has arrived at the gate.
    func untilSomeoneWaits() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { watchers.append($0) }
    }
}
