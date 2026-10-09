import Foundation
import FoundationModels
import Testing
@testable import PladderRefine

// Nothing here calls the model: Apple's calls are stood in for by sleeps run
// under the real wall-clock race, so the budget is the one the app enforces.

/// The polish's two calls, each a stand-in.
private struct StandInCalls: PolishCalls {
    typealias Call = @Sendable (_ prompt: String, _ deadline: ContinuousClock.Instant) async throws -> String

    var guidedCall: Call
    var plainCall: Call = { _, _ in
        Issue.record("no plain call expected")
        return ""
    }

    func guided(_ prompt: String, session: LanguageModelSession?, deadline: ContinuousClock.Instant) async throws -> String {
        try await guidedCall(prompt, deadline)
    }

    func plain(_ prompt: String, deadline: ContinuousClock.Instant) async throws -> String {
        try await plainCall(prompt, deadline)
    }
}

/// A model call that takes `duration` and then answers or throws, raced
/// against `deadline` the way `OnDeviceLanguageModel` races Apple's.
private func slowCall(
    _ duration: Duration, answer: String = "Cleaned.", throwing error: (any Error)? = nil,
    deadlines: Recorder<ContinuousClock.Instant>? = nil
) -> StandInCalls.Call {
    { _, deadline in
        deadlines?.append(deadline)
        return try await OnDeviceLanguageModel.race(until: deadline) {
            try await Task.sleep(for: duration)
            if let error { throw error }
            return answer
        }
    }
}

/// 700 words in sentences of seven: three chunks for Apple's model.
private let longTranscript = Array(repeating: "one two three four five six seven.", count: 100).joined(separator: " ")

@Suite(.timeLimit(.minutes(1))) struct TranscriptPolisherBudgetTests {
    // Before: every chunk got eight seconds of its own, so a dictation near
    // the 10 min cap could hold the paste for most of a minute.
    @Test func oneBudgetCoversEveryChunk() async {
        #expect(TranscriptPolisher.chunks(of: longTranscript).count == 3)
        let deadlines = Recorder<ContinuousClock.Instant>()
        // Each chunk alone is well inside the budget; three are not.
        let polisher = TranscriptPolisher(
            timeout: .milliseconds(60), calls: StandInCalls(guidedCall: slowCall(.milliseconds(25), deadlines: deadlines)))
        let started = ContinuousClock.now
        let report = await polisher.polish(longTranscript)
        #expect(report.text == nil)
        #expect(report.failure == "timed out")
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(Set(deadlines.all).count == 1)
    }

    @Test func chunksInsideTheBudgetArePolishedAndJoined() async {
        let polisher = TranscriptPolisher(
            timeout: .seconds(5), calls: StandInCalls(guidedCall: slowCall(.milliseconds(5), answer: "Done.")))
        let report = await polisher.polish(longTranscript)
        #expect(report.text == "Done. Done. Done.")
        #expect(report.chunks == 3)
        #expect(report.mode == .guided)
    }

    // Before: the plain fallback started a fresh eight seconds after the
    // guided call had used up its own.
    @Test func thePlainFallbackSharesTheBudget() async {
        let polisher = TranscriptPolisher(
            timeout: .milliseconds(60),
            calls: StandInCalls(
                guidedCall: slowCall(.milliseconds(40), throwing: OnDeviceModelError.decodingFailure),
                plainCall: slowCall(.milliseconds(40))))
        let report = await polisher.polish("send it on friday and copy anna")
        #expect(report.text == nil)
        #expect(report.failure == "timed out")
    }

    @Test func bothGuidedFailuresFallBackToPlainText() async {
        for failure in [OnDeviceModelError.decodingFailure, .unsupportedGuide] {
            let polisher = TranscriptPolisher(
                timeout: .seconds(5),
                calls: StandInCalls(
                    guidedCall: slowCall(.zero, throwing: failure),
                    plainCall: slowCall(.zero, answer: "Send it on Friday and copy Anna.")))
            let report = await polisher.polish("send it on friday and copy anna")
            #expect(report.text == "Send it on Friday and copy Anna.")
            #expect(report.mode == .plain)
        }
    }

    @Test func anyOtherErrorPastesAsDictatedWithoutAPlainCall() async {
        let polisher = TranscriptPolisher(
            timeout: .seconds(5),
            calls: StandInCalls(guidedCall: slowCall(.zero, throwing: OnDeviceModelError.generation("refusal"))))
        let report = await polisher.polish("send it on friday and copy anna")
        #expect(report.text == nil)
        #expect(report.failure == "model error refusal")
    }
}

@Suite(.timeLimit(.minutes(1))) struct OnDeviceModelErrorTests {
    private typealias GenerationError = LanguageModelSession.GenerationError

    @Test func theTwoGuidedFailuresAreTypedCases() {
        let context = GenerationError.Context(debugDescription: "send it on friday")
        #expect(OnDeviceLanguageModel.modelError(from: GenerationError.decodingFailure(context)) == .decodingFailure)
        #expect(OnDeviceLanguageModel.modelError(from: GenerationError.unsupportedGuide(context)) == .unsupportedGuide)
    }

    // The debug description is where the user's words can turn up; the log
    // line that carries this is public.
    @Test func anyOtherErrorKeepsItsNameAndNeverItsText() {
        let context = GenerationError.Context(debugDescription: "send it on friday")
        #expect(OnDeviceLanguageModel.modelError(from: GenerationError.guardrailViolation(context)) == .generation("guardrailViolation"))
        #expect(OnDeviceLanguageModel.modelError(from: GenerationError.rateLimited(context)) == .generation("rateLimited"))
        #expect(OnDeviceLanguageModel.modelError(from: CancellationError()) == .generation("CancellationError"))
        #expect(OnDeviceLanguageModel.modelError(from: OnDeviceModelError.timedOut) == .timedOut)
    }

    #if compiler(>=6.4)
    // The macOS 27 SDK's replacements for the same two failures. Neither
    // their text nor, on macOS 27, the old cases' text holds the case name
    // the old string match looked for.
    @Test func macOS27sErrorsMapToTheSameCases() {
        guard #available(macOS 27, *) else { return }
        let parsing = GeneratedContent.ParsingError(rawContent: "send it on friday", debugDescription: "send it on friday")
        #expect(OnDeviceLanguageModel.modelError(from: parsing) == .decodingFailure)
        let guide = LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "send it"))
        #expect(OnDeviceLanguageModel.modelError(from: guide) == .unsupportedGuide)
        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "send it on friday"))
        #expect(OnDeviceLanguageModel.modelError(from: guardrail) == .generation("guardrailViolation"))
    }
    #endif

    @Test func theRaceThrowsOnlyTypedErrors() async {
        let context = GenerationError.Context(debugDescription: "send it on friday")
        await #expect(throws: OnDeviceModelError.decodingFailure) {
            try await OnDeviceLanguageModel.race(until: .now + .seconds(5)) { () async throws -> String in
                throw GenerationError.decodingFailure(context)
            }
        }
    }

    @Test func aDeadlineAlreadyPastStartsNothing() async {
        let started = Recorder<Bool>()
        await #expect(throws: OnDeviceModelError.timedOut) {
            try await OnDeviceLanguageModel.race(until: .now - .seconds(1)) { () async throws -> String in
                started.append(true)
                return "late"
            }
        }
        #expect(started.all.isEmpty)
    }
}
