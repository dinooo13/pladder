import Foundation

extension DictationCoordinator.Insertion {
    /// The release-to-paste log line, the number the critical-path rule
    /// watches (see docs/BENCHMARKS.md for how to read it). `total` runs from
    /// `recordingStopped` to `inserted`. A polish cycle gets a line of its
    /// own label, so the plain one stays comparable; one predicate finds
    /// both. Numbers only: the transcript never goes in the log.
    public func timingLine(total: Duration, polishModel: String) -> String {
        func fmt(_ duration: Duration) -> String { String(format: "%.3f", duration.timeInterval) }
        let polish = timing.polish.map { "polish \(fmt($0)) (\(polishModel)), " } ?? ""
        let label = timing.polish == nil ? "release-to-paste" : "polished release-to-paste"
        let stages = "stop \(fmt(timing.captureStop)), engine \(fmt(timing.engine)), "
            + "process \(fmt(timing.processing)), \(polish)paste \(fmt(timing.insert))"
        return "\(label) \(fmt(total)) s: \(stages); "
            + String(format: "audio %.1f s, engine-time %.3f s", transcript.audioDuration, transcript.processingTime)
    }
}
