import Foundation
import Testing
@testable import PladderCore

private struct Emptying: TextProcessor {
    let id = "emptying"
    func process(_ text: String) -> String { "" }
}

private final class FixedRefiner: TranscriptRefiner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private let result: String
    var calls: [String] { lock.withLock { _calls } }

    init(result: String) { self.result = result }

    func prepare() async {}

    func refine(_ text: String) async -> String? {
        lock.withLock { _calls.append(text) }
        return result
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DictationFinishTests {
    private static let second = CapturedAudio(samples: Array(repeating: 0.1, count: 16_000))

    private func finish(
        pipeline: ProcessorPipeline = ProcessorPipeline([WhitespaceNormalizer()]),
        appendTrailingSpace: Bool = true,
        shortSentence: ShortSentence = ShortSentence(dropPeriod: false, dropCapital: false),
        refiner: FixedRefiner? = nil,
        output: FakeOutput = FakeOutput()
    ) -> DictationFinish {
        DictationFinish(
            pipeline: pipeline, disabledProcessors: [], appendTrailingSpace: appendTrailingSpace,
            shortSentence: shortSentence,
            willPolish: refiner != nil, refiner: refiner, minimumDuration: 0.3, minimumPolishWords: 4,
            output: output)
    }

    private func loaded(_ text: String, delay: Duration = .zero) async throws -> EchoEngine {
        let engine = EchoEngine(text: text, delay: delay)
        try await engine.load()
        return engine
    }

    private func input(
        _ source: DictationFinish.Source, audio: CapturedAudio = second, fed: Int = 0,
        captureStop: Duration = .zero, feedWait: Duration = .zero
    ) -> DictationFinish.Input {
        DictationFinish.Input(
            audio: audio, fedSamples: fed, source: source, submit: false,
            captureStop: captureStop, feedWait: feedWait)
    }

    private func run(_ finish: DictationFinish, _ input: DictationFinish.Input) async -> (
        DictationFinish.Outcome, [DictationFinish.Stage]
    ) {
        var stages: [DictationFinish.Stage] = []
        let outcome = await finish.run(input) { stages.append($0) }
        return (outcome, stages)
    }

    @Test func aRecordingUnderTheMinimumAbandonsTheUtteranceAndInsertsNothing() async throws {
        let engine = FakeStreamingEngine()
        try await engine.load()
        let utterance = try await engine.beginUtterance()
        let output = FakeOutput()
        let short = CapturedAudio(samples: Array(repeating: 0.1, count: 3_000))
        let (outcome, stages) = await run(
            finish(output: output), input(.utterance(engine, utterance), audio: short, fed: 1_000))
        #expect(outcome == .tooShort)
        #expect(stages.isEmpty)
        #expect(engine.log.last == "abandon")
        #expect(engine.endCount == 0)
        #expect(output.inserted.isEmpty)
    }

    @Test func fedSamplesCountTowardsTheMinimum() async throws {
        let engine = FakeStreamingEngine()
        try await engine.load()
        let utterance = try await engine.beginUtterance()
        let tail = CapturedAudio(samples: Array(repeating: 0.1, count: 1_000))
        let (outcome, _) = await run(finish(), input(.utterance(engine, utterance), audio: tail, fed: 16_000))
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.transcript.text == "final")
        #expect(insertion.transcript.audioDuration == 17_000 / CapturedAudio.sampleRate)
    }

    @Test func processedTextEmptyInsertsNothingAndReportsEmpty() async throws {
        let output = FakeOutput()
        let (outcome, stages) = await run(
            finish(pipeline: ProcessorPipeline([Emptying()]), output: output),
            input(.whole(try await loaded("um"))))
        #expect(outcome == .empty)
        #expect(stages.isEmpty)
        #expect(output.inserted.isEmpty)
    }

    @Test func polishRunsFromTheMinimumWordCountAndReportsItsStage() async throws {
        let refiner = FixedRefiner(result: "Polished.")
        let output = FakeOutput()
        let (outcome, stages) = await run(
            finish(refiner: refiner, output: output), input(.whole(try await loaded("one two three four"))))
        #expect(refiner.calls == ["one two three four"])
        #expect(stages.count == 2)
        #expect(stages.first == .polishing)
        #expect(output.inserted == ["Polished. "])
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.transcript.text == "Polished.")
        #expect(insertion.timing.polish != nil)
    }

    @Test func underTheMinimumPolishIsZeroNotNil() async throws {
        let refiner = FixedRefiner(result: "Polished.")
        let (outcome, stages) = await run(finish(refiner: refiner), input(.whole(try await loaded("one two three"))))
        #expect(refiner.calls.isEmpty)
        #expect(!stages.contains(.polishing))
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.timing.polish == .zero)
    }

    @Test func withoutPolishTheTimingHasNoPolishStage() async throws {
        let (outcome, _) = await run(finish(), input(.whole(try await loaded("one two three four"))))
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.timing.polish == nil)
    }

    @Test func theInsertingStageCarriesTheProcessedTranscriptBeforeTheInsert() async throws {
        let output = FakeOutput()
        output.shouldFail = true
        let pipeline = ProcessorPipeline([
            DictionaryReplacer(entries: [DictionaryEntry(from: "hello world", to: "Hello, World!")]),
        ])
        let (outcome, stages) = await run(
            finish(pipeline: pipeline, output: output), input(.whole(try await loaded("hello world"))))
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        guard case .inserting(let transcript) = stages.last else {
            Issue.record("expected the inserting stage, got \(stages)")
            return
        }
        #expect(transcript.text == "Hello, World!")
    }

    @Test func timingSumsTheStagesAndFeedWaitCountsAsEngineTime() async throws {
        // Real time: the timing is read from the wall clock.
        let engine = try await loaded("hello world", delay: .milliseconds(20))
        let (outcome, _) = await run(
            finish(), input(.whole(engine), captureStop: .milliseconds(7), feedWait: .milliseconds(40)))
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.timing.captureStop == .milliseconds(7))
        #expect(insertion.timing.engine >= .milliseconds(60))
        #expect(insertion.timing.processing > .zero)
        #expect(insertion.timing.insert > .zero)
    }

    @Test func aTrailingSpaceIsAppendedOnlyWhenMissing() async throws {
        let output = FakeOutput()
        let noProcessors = ProcessorPipeline([])
        _ = await run(finish(pipeline: noProcessors, output: output), input(.whole(try await loaded("spaced "))))
        _ = await run(finish(pipeline: noProcessors, output: output), input(.whole(try await loaded("bare"))))
        _ = await run(
            finish(pipeline: noProcessors, appendTrailingSpace: false, output: output),
            input(.whole(try await loaded("off"))))
        #expect(output.inserted == ["spaced ", "bare ", "off"])
    }

    @Test func aShortSentenceIsMadePlainAfterPolishAndOnlyWhenOn() async throws {
        let output = FakeOutput()
        let refiner = FixedRefiner(result: "Run this in the terminal: bash foo.")
        let (outcome, _) = await run(
            finish(shortSentence: ShortSentence(dropPeriod: true, dropCapital: true), refiner: refiner, output: output),
            input(.whole(try await loaded("run this in the terminal bash foo"))))
        _ = await run(finish(shortSentence: ShortSentence(dropPeriod: true, dropCapital: true), output: output), input(.whole(try await loaded("Yes."))))
        _ = await run(finish(output: output), input(.whole(try await loaded("No."))))
        #expect(output.inserted == ["run this in the terminal: bash foo ", "yes ", "No. "])
        guard case .inserted(let insertion) = outcome else {
            Issue.record("expected an insertion, got \(outcome)")
            return
        }
        #expect(insertion.transcript.text == "run this in the terminal: bash foo")
    }

    @Test func aThrowingInsertBecomesAFailure() async throws {
        let output = FakeOutput()
        output.shouldFail = true
        output.failure = OutputError.eventCreationFailed
        let (outcome, _) = await run(finish(output: output), input(.whole(try await loaded("hello world"))))
        #expect(outcome == .failed(.pasteKeystroke))
    }

    @Test func aThrowingEngineBecomesAFailureBeforeAnyStage() async throws {
        let engine = EchoEngine(text: "never loaded")
        let (outcome, stages) = await run(finish(), input(.whole(engine)))
        #expect(outcome == .failed(.engineNotLoaded))
        #expect(stages.isEmpty)
    }
}
