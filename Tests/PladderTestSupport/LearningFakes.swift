import Foundation
import PladderCore

public final class FakePasteObserver: PastedTextObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [PasteObservation?]
    private var _pasted: [String] = []

    public init(_ script: [PasteObservation?]) { self.script = script }

    public var pasted: [String] { lock.withLock { _pasted } }

    public func observe(pasted: String) async -> PasteObservation? {
        lock.withLock {
            _pasted.append(pasted)
            return script.isEmpty ? nil : script.removeFirst()
        }
    }
}

public final class FakeCorrectionReviewer: CorrectionReviewer, @unchecked Sendable {
    public struct Failure: Error {
        public init() {}
    }

    public let isAvailable: Bool
    private let lock = NSLock()
    private let verdicts: [String: Bool]
    private let failing: Set<String>
    private let failure: any Error
    private var _calls: [(heard: String, corrected: String, sentence: String)] = []

    public init(
        available: Bool = true, verdicts: [String: Bool] = [:], failing: Set<String> = [],
        failure: any Error = Failure()
    ) {
        isAvailable = available
        self.verdicts = verdicts
        self.failing = failing
        self.failure = failure
    }

    public var calls: [(heard: String, corrected: String, sentence: String)] { lock.withLock { _calls } }

    public func isReusableCorrection(heard: String, corrected: String, sentence: String) async throws -> Bool {
        lock.withLock { _calls.append((heard, corrected, sentence)) }
        if failing.contains(heard) { throw failure }
        return verdicts[heard] ?? true
    }
}
