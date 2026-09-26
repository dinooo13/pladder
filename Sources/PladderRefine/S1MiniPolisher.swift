import Foundation
import PladderCore
import os

/// The polish on S1-mini by Superwhisper: Qwen3-0.6B fine-tuned to clean
/// dictation (fillers, self-corrections, spoken punctuation, numbers, lists),
/// run by llama.cpp on the GPU.
///
/// Trained on English only, it still resolved German and Spanish
/// self-corrections and lists on the polish set, and translated nothing,
/// where Apple's model turned two of them into English (docs/BENCHMARKS.md).
/// Its prompt is the one it was trained on, not `TranscriptPolisher`'s: a
/// fixed system line and a control line, then the transcript.
///
/// Best effort like the Apple polisher: no file yet, a load that fails, the
/// time budget, an empty answer all return nil and the coordinator pastes
/// the text as dictated. The model stays loaded from the first `prepare()`
/// until `unload()`, as the speech engine does.
public actor S1MiniPolisher: TranscriptRefiner {
    /// S1-mini's system prompt, word for word from its model card; it is
    /// part of the input format the model was trained on.
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// Semi-formal keeps the capitals a dictation into any app wants
    /// (semi-casual lower-cases sentence starts, formal rewrites "let's" as
    /// "let us"), and lists lets spoken enumerations become lines without
    /// forcing a list where there is none. Chosen on the polish set.
    public static let controlLine = "[Styling: semi-formal] [Structure: lists] [Context: general]"

    /// The part of the prompt that never changes, decoded once at load.
    /// Qwen's chat format, written out: the model's template would add the
    /// same, and a thinking block must stay empty (`enable_thinking=False`).
    static let promptPrefix = promptPrefix(control: controlLine)

    static func promptPrefix(control: String) -> String {
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(control)\n"
    }

    static func promptSuffix(for transcript: String) -> String {
        "\(transcript)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// The context holds 2,048 tokens for the prompt, the chunk and its
    /// answer, so chunks are smaller than the Apple polisher's.
    static let chunkThreshold = 400
    static let chunkSize = 250

    public nonisolated let file: ModelFile
    private let location: URL
    private let timeout: Duration
    private var model: LlamaModel?
    private var loading: Task<LlamaModel?, Never>?
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "polish")

    /// `location` is where `ModelFiles` keeps `file`.
    /// The control line this polisher sends; the CLI can try another.
    private let control: String

    /// `location` is where `ModelFiles` keeps `file`. `control` is for the
    /// CLI, which judges a style or a fine-tune of S1-mini before it goes in;
    /// the app always uses the default.
    public init(
        file: ModelFile, location: URL, timeout: Duration = .seconds(8),
        control: String = S1MiniPolisher.controlLine
    ) {
        self.file = file
        self.location = location
        self.timeout = timeout
        self.control = control
    }

    /// Loads the model if its file is there. Called at key-down, so a first
    /// dictation's load happens while the user is still speaking.
    public func prepare() async {
        _ = await loaded()
    }

    public func refine(_ text: String) async -> String? {
        await polish(text).text
    }

    /// Sets up llama.cpp without loading a model: cheap except on the first
    /// launch after an install, when Metal compiles its shaders for seconds.
    /// The app calls it as soon as S1-mini is chosen, so no dictation waits.
    public static func warmUpRuntime() async {
        await LlamaModel.warmUp()
    }

    /// Frees the model's memory; the next `prepare()` loads it again.
    public func unload() {
        loading?.cancel()
        loading = nil
        model = nil
    }

    /// `refine` with the numbers kept, for the log and the CLI. One log line
    /// per call, numbers only: the transcript never goes in the log.
    public func polish(_ text: String) async -> TranscriptPolisher.Report {
        let started = ContinuousClock.now
        let deadline = started + timeout
        let pieces = TranscriptPolisher.chunks(of: text, threshold: Self.chunkThreshold, size: Self.chunkSize)
        var report = TranscriptPolisher.Report(
            text: nil, elapsed: .zero, wordsIn: TranscriptPolisher.wordCount(text), wordsOut: 0,
            chunks: pieces.count, mode: .completion, failure: nil)
        if let model = await loaded() {
            do {
                var cleaned: [String] = []
                for piece in pieces {
                    // Room for an answer somewhat longer than the input: a
                    // list adds line breaks and dashes.
                    let maxTokens = TranscriptPolisher.wordCount(piece) * 3 + 64
                    let answer = try await model.complete(
                        suffix: Self.promptSuffix(for: piece), maxTokens: maxTokens, deadline: deadline)
                    let filtered = PolishPostFilter.clean(answer)
                    guard !filtered.isEmpty else { throw EmptyAnswer() }
                    cleaned.append(filtered)
                }
                let joined = cleaned.joined(separator: " ")
                report.text = joined
                report.wordsOut = TranscriptPolisher.wordCount(joined)
            } catch LlamaModel.Failure.timedOut {
                report.failure = "timed out"
            } catch is EmptyAnswer {
                report.failure = "empty answer"
            } catch {
                report.failure = "model error \(error)"
            }
        } else {
            report.failure = FileManager.default.fileExists(atPath: location.path) ? "model did not load" : "not downloaded"
        }
        report.elapsed = ContinuousClock.now - started
        Self.log(report, file: file)
        return report
    }

    private struct EmptyAnswer: Error {}

    /// The loaded model, loading it first if its file is there; nil
    /// otherwise. Concurrent callers share one load.
    private func loaded() async -> LlamaModel? {
        if let model { return model }
        if let loading { return await loading.value }
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let path = location.path
        let prefix = Self.promptPrefix(control: control)
        let task = Task { try? await LlamaModel.load(path: path, prefix: prefix) }
        loading = task
        let model = await task.value
        // `unload()` during the load cancelled this task: drop the result.
        if loading == task, !task.isCancelled { self.model = model }
        if loading == task { loading = nil }
        return self.model
    }

    private static func log(_ report: TranscriptPolisher.Report, file: ModelFile) {
        let secs = String(format: "%.3f", Double(report.elapsed.components.seconds)
            + Double(report.elapsed.components.attoseconds) / 1e18)
        if let failure = report.failure {
            log.notice(
                "polish (\(file.fileName, privacy: .public)) failed after \(secs, privacy: .public) s, \(report.wordsIn, privacy: .public) words in: \(failure, privacy: .public)")
        } else {
            log.notice(
                """
                polish (\(file.fileName, privacy: .public)) \(secs, privacy: .public) s, \
                \(report.wordsIn, privacy: .public) words in, \(report.wordsOut, privacy: .public) out\
                \(report.chunks > 1 ? ", \(report.chunks) chunks" : "", privacy: .public)
                """)
        }
    }
}
