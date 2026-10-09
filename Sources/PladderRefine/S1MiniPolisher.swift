import Foundation
import PladderCore
import os

// See docs/ARCHITECTURE.md, "Polish". Its prompt is the format it was trained on,
// not `TranscriptPolisher`'s.
public actor S1MiniPolisher: ReportingRefiner {
    // Word for word from the model card: part of the input format it was trained on.
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    // Semi-formal keeps the capitals (semi-casual lower-cases sentence starts, formal
    // writes "let us"); lists turns spoken enumerations into lines. Chosen on the polish set.
    public static let controlLine = "[Styling: semi-formal] [Structure: lists] [Context: general]"

    // Decoded once at load. Qwen's chat format written out; the thinking block must stay
    // empty (`enable_thinking=False`).
    static let promptPrefix = promptPrefix(control: controlLine)

    static func promptPrefix(control: String) -> String {
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(control)\n"
    }

    static func promptSuffix(for transcript: String) -> String {
        "\(transcript)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    // 2,048 tokens of context hold the prompt, the chunk and its answer.
    static let chunkThreshold = 400
    static let chunkSize = 250

    typealias Loader = @Sendable (_ path: String, _ prefix: String) async throws -> any PromptCompleter

    public nonisolated let file: ModelFile
    private let location: URL
    private let timeout: Duration
    private let control: String
    private let load: Loader
    private var model: (any PromptCompleter)?
    private var loading: Task<(any PromptCompleter)?, Never>?
    // Bumped by `unload()`, so a load it interrupted cannot store its model.
    private var generation = 0
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "polish")

    public init(
        file: ModelFile, location: URL, timeout: Duration = .seconds(8),
        control: String = S1MiniPolisher.controlLine
    ) {
        self.init(file: file, location: location, timeout: timeout, control: control) {
            try await LlamaModel.load(path: $0, prefix: $1)
        }
    }

    init(file: ModelFile, location: URL, timeout: Duration, control: String, load: @escaping Loader) {
        self.file = file
        self.location = location
        self.timeout = timeout
        self.control = control
        self.load = load
    }

    public func prepare() async {
        guard model == nil, let task = startLoad() else { return }
        _ = await task.value
    }

    public func refine(_ text: String) async -> String? {
        await polish(text).text
    }

    // Cheap, except on the first launch after an install, when Metal compiles its
    // shaders for seconds.
    public static func warmUpRuntime() async {
        await LlamaModel.warmUp()
    }

    public func unload() {
        loading?.cancel()
        loading = nil
        model = nil
        generation += 1
    }

    // The budget covers the wait for the model too: a first dictation can find the load
    // running, pastes as dictated at the deadline, and the load carries on.
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
                    // Room for an answer somewhat longer than the input: a list adds breaks and dashes.
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
        case stillLoading
        case noModel
    }

    private func loaded(before deadline: ContinuousClock.Instant) async -> Loaded {
        if let model { return .ready(model) }
        guard let task = startLoad() else { return .noModel }
        // Not a task group: that would wait for the load however long it took.
        guard let model = await firstOf(until: deadline, { await task.value }).value else { return .stillLoading }
        return model.map(Loaded.ready) ?? .noModel
    }

    // The load stores its own result, so a caller that stopped waiting at its deadline
    // still leaves the model for the next dictation.
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
        guard generation == self.generation else { return }
        self.model = model
        loading = nil
    }
}

protocol PromptCompleter: Sendable {
    func complete(suffix: String, maxTokens: Int, deadline: ContinuousClock.Instant) async throws -> String
}

extension LlamaModel: PromptCompleter {}
