// TEMPORARY, removed when the output branch merges: it gives OutputMuter the
// session-numbered calls the coordinator makes.
extension OutputMuter {
    func recordingStarted(session: Int) async { await recordingStarted() }
    func recordingEnded(session: Int) async { await recordingEnded() }
}
