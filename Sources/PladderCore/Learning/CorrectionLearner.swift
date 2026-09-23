import Foundation

/// Turns the user's hand corrections of a pasted dictation into proposed
/// dictionary rules.
///
/// Runs strictly after the paste and never on the release-to-paste path:
/// `pasted` returns at once and everything else happens on a detached
/// utility task. Per paste, in this order, each step cheaper than the next:
///
/// 1. The reviewer must be available; otherwise the field is not even
///    watched, and the feature is absent.
/// 2. The observer watches the field and returns what it saw.
/// 3. `CorrectionDiff` finds the corrected words.
/// 4. Pairs already in the dictionary, or dismissed before, are dropped.
/// 5. `PhoneticGate` drops what does not sound alike.
/// 6. The reviewer, the on-device model, says yes or no to each survivor.
/// 7. Each yes is handed to `onProposal`, at most
///    `maximumProposalsPerPaste` of them.
///
/// A second paste while the first is still being watched just starts its own
/// task; the observer finishes the first watch early with what it has, and
/// both are diffed and reviewed on their own.
public final class CorrectionLearner: Sendable {
    public static let maximumProposalsPerPaste = 3
    /// The context the reviewer sees around a pair, in characters.
    static let sentenceLimit = 400

    private let observer: any PastedTextObserver
    private let reviewer: any CorrectionReviewer
    private let dismissed: DismissedCorrections
    private let dictionary: @Sendable () async -> [DictionaryEntry]
    private let log: @Sendable (String) -> Void
    private let onProposal: @Sendable (CorrectionProposal) -> Void

    /// `log` receives one line per stage, with the words in it; the caller
    /// decides how private that is.
    public init(
        observer: any PastedTextObserver,
        reviewer: any CorrectionReviewer,
        dismissed: DismissedCorrections,
        dictionary: @escaping @Sendable () async -> [DictionaryEntry],
        log: @escaping @Sendable (String) -> Void = { _ in },
        onProposal: @escaping @Sendable (CorrectionProposal) -> Void
    ) {
        self.observer = observer
        self.reviewer = reviewer
        self.dismissed = dismissed
        self.dictionary = dictionary
        self.log = log
        self.onProposal = onProposal
    }

    /// Non-blocking. Called once per paste with the text that was pasted.
    /// The task is returned for tests; the app drops it.
    @discardableResult
    public func pasted(_ text: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            await learn(from: text)
        }
    }

    private func learn(from text: String) async {
        guard reviewer.isAvailable else { return }
        guard let observation = await observer.observe(pasted: text) else {
            log("no anchor")
            return
        }
        let pairs = CorrectionDiff.candidates(in: observation)
        log("\(pairs.count) candidates")
        guard !pairs.isEmpty else { return }

        let known = Set(await dictionary().compactMap { entry -> String? in
            let from = entry.from.trimmingCharacters(in: .whitespaces).lowercased()
            return from.isEmpty ? nil : from
        })
        var seen: Set<String> = []
        var proposed = 0
        for pair in pairs where seen.insert(pair.key).inserted {
            let name = "\(pair.heard) → \(pair.corrected)"
            if known.contains(pair.heard.lowercased()) {
                log("in the dictionary \(name)")
                continue
            }
            if await dismissed.contains(pair) {
                log("dismissed before \(name)")
                continue
            }
            guard PhoneticGate.isClose(pair.heard, pair.corrected) else {
                log("gate dropped \(name)")
                continue
            }
            do {
                let yes = try await reviewer.isReusableCorrection(
                    heard: pair.heard, corrected: pair.corrected,
                    sentence: Self.sentence(around: pair.heard, in: observation.pasted))
                log("review \(yes ? "yes" : "no") \(name)")
                guard yes else { continue }
                onProposal(CorrectionProposal(pair: pair))
                proposed += 1
                if proposed >= Self.maximumProposalsPerPaste { return }
            } catch {
                log("review failed \(name): \(error)")
            }
        }
    }

    /// The pasted text, cut to `limit` characters around `heard` when it is
    /// longer, so the model sees the word in its sentence and not a page.
    static func sentence(around heard: String, in pasted: String, limit: Int = sentenceLimit) -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let middle = text.range(of: heard).map {
            text.distance(from: text.startIndex, to: $0.lowerBound) + heard.count / 2
        } ?? text.count / 2
        let start = max(0, min(text.count - limit, middle - limit / 2))
        let from = text.index(text.startIndex, offsetBy: start)
        return String(text[from..<text.index(from, offsetBy: limit)])
    }
}
