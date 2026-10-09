import Foundation
import PladderCore

public struct PolishReport: Sendable {
    public enum Mode: String, Sendable {
        case guided
        case plain
        case completion
    }

    public var text: String?
    public var elapsed: Duration
    public var wordsIn: Int
    public var wordsOut: Int
    public var chunks: Int
    public var mode: Mode
    // Never contains the transcript.
    public var failure: String?
}

public protocol ReportingRefiner: TranscriptRefiner {
    func polish(_ text: String) async -> PolishReport
}

extension PolishReport {
    func logLine(model: String? = nil) -> String {
        let name = model.map { "polish (\($0))" } ?? "polish"
        let secs = String(format: "%.3f", elapsed.timeInterval)
        if let failure { return "\(name) failed after \(secs) s, \(wordsIn) words in: \(failure)" }
        let modeText = mode == .completion ? "" : ", \(mode.rawValue)"
        let chunksText = chunks > 1 ? ", \(chunks) chunks" : ""
        return "\(name) \(secs) s, \(wordsIn) words in, \(wordsOut) out\(modeText)\(chunksText)"
    }
}
