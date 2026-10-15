import Foundation

extension DictationCoordinator.Insertion {
    // Numbers only: the transcript never goes in the log. A polish cycle has a label
    // of its own, so the plain line stays comparable (docs/BENCHMARKS.md).
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
