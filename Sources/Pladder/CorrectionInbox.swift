import Foundation
import Observation
import os
import PladderCore
import PladderRefine
import PladderSystem

/// The learned-corrections menu lines: the learner watches a field after
/// each paste and proposes what the user corrected; this keeps the proposals
/// until the user answers Add or Dismiss.
///
/// Nothing here runs before the paste: `pasted` hands the text over and the
/// learner watches and reviews on its own thread and task.
@MainActor
@Observable
final class CorrectionInbox {
    /// Corrections the model agreed with, newest first. Kept for the app's
    /// life or until answered.
    private(set) var proposals: [CorrectionProposal] = []
    static let maximumProposals = 3

    /// The dictionary as it is now, and how a rule gets into it. Set by the
    /// app once it exists.
    @ObservationIgnored var dictionary: () -> [DictionaryEntry] = { [] }
    @ObservationIgnored var addRules: ([DictionaryEntry]) -> Void = { _ in }

    @ObservationIgnored private let dismissed: DismissedCorrections
    @ObservationIgnored private let relay = MainActorRelay<CorrectionProposal>()
    @ObservationIgnored private var learner: CorrectionLearner?

    /// The learner's stages. They quote the user's words, so the text is
    /// `.private`: `log show` prints it only with private data on.
    private nonisolated static let log = Logger(subsystem: "de.dinooo13.pladder", category: "learning")

    init(dismissedURL: URL) {
        dismissed = DismissedCorrections(url: dismissedURL)
        let relay = self.relay
        learner = CorrectionLearner(
            observer: AXPasteObserver(),
            reviewer: FoundationModelsCorrectionReviewer(),
            dismissed: dismissed,
            dictionary: { [weak self] in await self?.currentDictionary() ?? [] },
            log: { Self.log.info("\($0, privacy: .private)") },
            onProposal: { relay.send($0) }
        )
        relay.handler = { [weak self] in self?.propose($0) }
    }

    private func currentDictionary() -> [DictionaryEntry] { dictionary() }

    /// The text that was pasted, strictly after the paste.
    func pasted(_ text: String) {
        learner?.pasted(text)
    }

    /// Adds `heard → corrected` to the dictionary, overwriting a rule with the
    /// same `from` the way the Dictionary tab's import does.
    func accept(_ proposal: CorrectionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        addRules([DictionaryEntry(from: proposal.pair.heard, to: proposal.pair.corrected)])
    }

    /// Drops the line and remembers the pair so it is never proposed again.
    func dismiss(_ proposal: CorrectionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        let dismissed = self.dismissed
        Task { await dismissed.dismiss(proposal.pair) }
    }

    private func propose(_ proposal: CorrectionProposal) {
        let key = proposal.pair.key
        guard !proposals.contains(where: { $0.pair.key == key }),
              !dictionary().hasRule(for: proposal.pair.heard) else { return }
        proposals = Array(([proposal] + proposals).prefix(Self.maximumProposals))
    }
}
