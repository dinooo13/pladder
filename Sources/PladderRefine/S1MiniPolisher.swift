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
public actor S1MiniPolisher: ReportingRefiner {
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

    /// Loads the model at a path with a prompt prefix; `LlamaModel.load` in
    /// the app, a stand-in in the tests.
    typealias Loader = @Sendable (_ path: String, _ prefix: String) async throws -> any PromptCompleter

    public nonisolated let file: ModelFile
    private let location: URL
    private let timeout: Duration
    /// The control line this polisher sends; the CLI can try another.
    private let control: String
    private let load: Loader
    private var model: (any PromptCompleter)?
    private var loading: Task<(any PromptCompleter)?, Never>?
    /// Bumped by `unload()`, so a load it interrupted cannot store its model.
    private var generation = 0
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "polish")

    /// `location` is where `ModelFiles` keeps `file`. `control` is for the
    /// CLI, which judges a style or a fine-tune of S1-mini before it goes in;
    /// the app always uses the default.
    public init(
        file: ModelFile, location: URL, timeout: Duration = .seconds(8),
        control: String = S1MiniPolisher.controlLine
    ) {
        self.init(file: file, location: location, timeout: timeout, control: control) {
            try await LlamaModel.load(path: $0, prefix: $1)
        }
    }

    /// `load` stands in for llama.cpp in the tests.
    init(file: ModelFile, location: URL, timeout: Duration, control: String, load: @escaping Loader) {
        self.file = file
        self.location = location
        self.timeout = timeout
        self.control = control
        self.load = load
    }

    /// Loads the model if its file is there, however long that takes. Called
    /// at key-down, so a first dictation's load happens while the user is
    /// still speaking; the CLI awaits it to time a warm polish.
    public func prepare() async {
        guard model == nil, let task = startLoad() else { return }
        _ = await task.value
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
        generation += 1
    }

    /// `refine` with the numbers kept, for the log and the CLI. One log line
    /// per call, numbers only: the transcript never goes in the log.
    ///
    /// The budget starts here and covers the wait for the model as well as
    /// every chunk. A first dictation after launch can find the load still
    /// running (seconds of reading weights, and on the first launch after an
    /// install seven more of Metal compiling its shaders); it pastes as
    /// dictated at the deadline, and the load carries on for the next one.
    public func polish(_ text: String) async -> PolishReport {
        let started = ContinuousClock.now
        let deadline = started + timeout
        let pieces = PolishChunking.chunks(of: text, threshold: Self.chunkThreshold, size: Self.chunkSize)
        var report = PolishReport(
            text: nil, elapsed: .zero, wordsIn: PolishChunking.wordCount(text), wordsOut: 0,
            chunks: pieces.count, mode: .completion, failure: nil)
        switch await loaded(before: deadline) {
        case .ready(let model):
            do {
                var cleaned: [String] = []
                for piece in pieces {
                    // Room for an answer somewhat longer than the input: a
                    // list adds line breaks and dashes.
                    let maxTokens = PolishChunking.wordCount(piece) * 3 + 64
                    let answer = try await model.complete(
                        suffix: Self.promptSuffix(for: piece), maxTokens: maxTokens, deadline: deadline)
                    let filtered = PolishPostFilter.clean(answer)
                    guard !filtered.isEmpty else { throw EmptyAnswer() }
                    cleaned.append(filtered)
                }
                let joined = cleaned.joined(separator: " ")
                report.text = joined
                report.wordsOut = PolishChunking.wordCount(joined)
            } catch LlamaModel.Failure.timedOut {
                report.failure = "timed out"
            } catch LlamaModel.Failure.truncated {
                report.failure = "answer cut off"
            } catch is EmptyAnswer {
                report.failure = "empty answer"
            } catch {
                report.failure = "model error \(error)"
            }
        case .stillLoading:
            report.failure = "still loading"
        case .noModel:
            report.failure = FileManager.default.fileExists(atPath: location.path) ? "model did not load" : "not downloaded"
        }
        report.elapsed = ContinuousClock.now - started
        Self.log.notice("\(report.logLine(model: self.file.fileName), privacy: .public)")
        return report
    }

    private struct EmptyAnswer: Error {}

    // MARK: Loading

    private enum Loaded: Sendable {
        case ready(any PromptCompleter)
        /// The load is still running at the deadline; it carries on.
        case stillLoading
        /// No file, or a load that failed.
        case noModel
    }

    /// The loaded model, waiting for a running load (or starting one, if the
    /// file is there) until `deadline` at most.
    private func loaded(before deadline: ContinuousClock.Instant) async -> Loaded {
        if let model { return .ready(model) }
        guard let task = startLoad() else { return .noModel }
        // Not a task group: that would wait for the load however long it
        // took. The waiter left behind ends with the load.
        guard let model = await firstOf(until: deadline, { await task.value }).value else { return .stillLoading }
        return model.map(Loaded.ready) ?? .noModel
    }

    /// The running load, or a new one if the file is there; nil without a
    /// file. Concurrent callers share one load. The load stores its own
    /// result, so a caller that stopped waiting at its deadline still leaves
    /// the model for the next dictation.
    private func startLoad() -> Task<(any PromptCompleter)?, Never>? {
        if let loading { return loading }
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let path = location.path
        let prefix = Self.promptPrefix(control: control)
        let load = load
        let generation = generation
        let task = Task {
            let model = try? await load(path, prefix)
            self.finishLoad(model, generation: generation)
            return model
        }
        loading = task
        return task
    }

    private func finishLoad(_ model: (any PromptCompleter)?, generation: Int) {
        // `unload()` during the load: drop the result.
        guard generation == self.generation else { return }
        self.model = model
        loading = nil
    }
}

/// What the polisher needs of a loaded model. `LlamaModel` is the real one;
/// the tests stand in for it, so the deadline and failure handling run
/// without a model file.
protocol PromptCompleter: Sendable {
    func complete(suffix: String, maxTokens: Int, deadline: ContinuousClock.Instant) async throws -> String
}

extension LlamaModel: PromptCompleter {}
