import Foundation
import Observation
import os
import PladderCore
import PladderRefine
import PladderSystem

@MainActor
@Observable
final class CorrectionInbox {
    private(set) var proposals: [CorrectionProposal] = []
    static let maximumProposals = 3
    @ObservationIgnored var dictionary: () -> [DictionaryEntry] = { [] }
    @ObservationIgnored var addRules: ([DictionaryEntry]) -> Void = { _ in }
    @ObservationIgnored var waitUntilQuiet: @MainActor () async -> Void = {}

    @ObservationIgnored private let dismissed: DismissedCorrections
    @ObservationIgnored private let relay = MainActorRelay<CorrectionProposal>()
    @ObservationIgnored private var learner: CorrectionLearner?

    // The stages quote the user's words, so the text is `.private`.
    private nonisolated static let log = Logger(subsystem: "de.dinooo13.pladder", category: "learning")

    init(
        dismissedURL: URL,
        observer: any PastedTextObserver = AXPasteObserver(),
        reviewer: any CorrectionReviewer = FoundationModelsCorrectionReviewer()
    ) {
        dismissed = DismissedCorrections(url: dismissedURL)
        let relay = self.relay
        learner = CorrectionLearner(
            observer: observer,
            reviewer: reviewer,
            dismissed: dismissed,
            dictionary: { [weak self] in await self?.currentDictionary() ?? [] },
            log: { Self.log.info("\($0, privacy: .private)") },
            waitUntilQuiet: { [weak self] in await self?.waitForQuiet() },
            onProposal: { relay.send($0) }
        )
        relay.handler = { [weak self] in self?.propose($0) }
    }

    private func currentDictionary() -> [DictionaryEntry] { dictionary() }
    private func waitForQuiet() async { await waitUntilQuiet() }

    func pasted(_ text: String) {
        learner?.pasted(text)
    }

    func accept(_ proposal: CorrectionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        addRules([DictionaryEntry(from: proposal.pair.heard, to: proposal.pair.corrected)])
    }

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
