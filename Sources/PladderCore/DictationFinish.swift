import Foundation

// See docs/ARCHITECTURE.md, "Dictation flow".
@MainActor
struct DictationFinish {
    enum Source {
        case utterance(any StreamingTranscriptionEngine, Utterance)
        case whole(any TranscriptionEngine)
    }

    struct Input {
        var audio: CapturedAudio
        // A streaming engine was fed these while recording; `audio` is only the tail.
        var fedSamples: Int
        var source: Source
        var submit: Bool
        var captureStop: Duration
        var feedWait: Duration
    }

    enum Stage: Equatable {
        case polishing
        // Before the insert, so a paste that fails leaves the processed text as the
        // last transcript, which is when the user needs it.
        case inserting(Transcript)
    }

    enum Outcome: Equatable {
        case tooShort
        case empty
        case inserted(DictationCoordinator.Insertion)
        case failed(DictationFailure)
    }

    let pipeline: ProcessorPipeline
    let disabledProcessors: Set<String>
    let appendTrailingSpace: Bool
    let shortSentence: ShortSentence
    let willPolish: Bool
    let refiner: (any TranscriptRefiner)?
    let minimumDuration: TimeInterval
    let minimumPolishWords: Int
    let output: any TextOutput

    func run(_ input: Input, onStage: (Stage) -> Void) async -> Outcome {
        let totalDuration = Double(input.fedSamples + input.audio.samples.count) / CapturedAudio.sampleRate
        guard totalDuration >= minimumDuration else {
            if case .utterance(let engine, let utterance) = input.source {
                await engine.abandonUtterance(utterance)
            }
            return .tooShort
        }
        do {
            var timing = DictationCoordinator.CycleTiming(
                captureStop: input.captureStop, engine: .zero, processing: .zero, insert: .zero)
            var started = ContinuousClock.now
            var transcript = switch input.source {
            case .utterance(let engine, let utterance):
                try await engine.endUtterance(utterance, tail: input.audio.samples)
            case .whole(let engine):
                try await engine.transcribe(input.audio.samples)
            }
            timing.engine = input.feedWait + (ContinuousClock.now - started)
            if transcript.audioDuration == 0 {
                transcript.audioDuration = totalDuration
            }
            started = ContinuousClock.now
            let processed = pipeline.run(transcript.text, disabled: disabledProcessors)
            timing.processing = ContinuousClock.now - started
            guard !processed.isEmpty else { return .empty }
            var final = processed
            if willPolish, let refiner, processed.wordCount >= minimumPolishWords {
                onStage(.polishing)
                started = ContinuousClock.now
                if let polished = await refiner.refine(processed) { final = polished }
                timing.polish = ContinuousClock.now - started
            } else if willPolish {
                timing.polish = .zero
            }
            // After polish, which would put the capital and the stop back.
            final = shortSentence.apply(final)
            let needsSpace = appendTrailingSpace && final.last?.isWhitespace != true
            let toInsert = needsSpace ? final + " " : final
            transcript.text = final
            onStage(.inserting(transcript))
            started = ContinuousClock.now
            let result = try await output.insert(toInsert, submit: input.submit)
            timing.insert = ContinuousClock.now - started
            return .inserted(DictationCoordinator.Insertion(
                transcript: transcript, timing: timing, result: result,
                submitted: input.submit && result == .pasted))
        } catch {
            return .failed(DictationFailure(error))
        }
    }
}
