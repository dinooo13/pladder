import Foundation

// See docs/ARCHITECTURE.md, "Learned corrections". The reviewer shares the system's
// language model with the polish, and it answers one request at a time, so
// `waitUntilQuiet` is awaited before every question, never while one is answered.
public final class CorrectionLearner: Sendable {
    public static let maximumProposalsPerPaste = 3
    static let sentenceLimit = 400

    private let observer: any PastedTextObserver
    private let reviewer: any CorrectionReviewer
    private let dismissed: DismissedCorrections
    private let dictionary: @Sendable () async -> [DictionaryEntry]
    private let log: @Sendable (String) -> Void
    private let waitUntilQuiet: @Sendable () async -> Void
    private let onProposal: @Sendable (CorrectionProposal) -> Void

    // `log` gets one line per stage, with the words in it; the caller decides how
    // private that is.
    public init(
        observer: any PastedTextObserver,
        reviewer: any CorrectionReviewer,
        dismissed: DismissedCorrections,
        dictionary: @escaping @Sendable () async -> [DictionaryEntry],
        log: @escaping @Sendable (String) -> Void = { _ in },
        waitUntilQuiet: @escaping @Sendable () async -> Void = {},
        onProposal: @escaping @Sendable (CorrectionProposal) -> Void
    ) {
        self.observer = observer
        self.reviewer = reviewer
        self.dismissed = dismissed
        self.dictionary = dictionary
        self.log = log
        self.waitUntilQuiet = waitUntilQuiet
        self.onProposal = onProposal
    }

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

        let rules = await dictionary()
        var seen: Set<String> = []
        var proposed = 0
        for pair in pairs where seen.insert(pair.key).inserted {
            let name = "\(pair.heard) → \(pair.corrected)"
            if rules.hasRule(for: pair.heard) {
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
            await waitUntilQuiet()
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
                log("review failed \(name): \(Self.describe(error))")
            }
        }
    }

    // The type and case, never the payload or description: a framework error can quote
    // the prompt, and the prompt is the user's words.
    static func describe(_ error: any Error) -> String {
        let name = String(describing: type(of: error))
        if type(of: error) is NSError.Type {
            let error = error as NSError
            return "\(name) \(error.domain) \(error.code)"
        }
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return name }
        // A case with a payload is the label of its one child.
        if let label = mirror.children.first?.label { return "\(name).\(label)" }
        // One without carries no data, so its description cannot quote any.
        return "\(name).\(String(describing: error))"
    }

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
