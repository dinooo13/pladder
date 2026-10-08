import Testing
@testable import PladderCore

@Suite struct TimingLineTests {
    private func insertion(polish: Duration?) -> DictationCoordinator.Insertion {
        DictationCoordinator.Insertion(
            transcript: Transcript(text: "secret words", audioDuration: 4.24, processingTime: 0.2504, engineID: EngineID("e")),
            timing: .init(
                captureStop: .milliseconds(12), engine: .milliseconds(250),
                processing: .milliseconds(3), insert: .milliseconds(14), polish: polish),
            result: .pasted, submitted: false)
    }

    @Test func thePlainLineKeepsTheFormatTheDocsDescribe() {
        #expect(insertion(polish: nil).timingLine(total: .milliseconds(312), polishModel: "appleIntelligence")
            == "release-to-paste 0.312 s: stop 0.012, engine 0.250, process 0.003, paste 0.014; audio 4.2 s, engine-time 0.250 s")
    }

    @Test func aPolishCycleHasItsOwnLabelAndStage() {
        #expect(insertion(polish: .milliseconds(1620)).timingLine(total: .milliseconds(1912), polishModel: "s1Mini")
            == "polished release-to-paste 1.912 s: stop 0.012, engine 0.250, process 0.003, polish 1.620 (s1Mini), paste 0.014; audio 4.2 s, engine-time 0.250 s")
    }

    @Test func theTranscriptNeverReachesTheLine() {
        #expect(!insertion(polish: nil).timingLine(total: .zero, polishModel: "x").contains("secret"))
    }
}
