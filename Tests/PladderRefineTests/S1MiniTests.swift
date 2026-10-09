import Foundation
import PladderCore
import PladderTestSupport
import Testing
@testable import PladderRefine

// Nothing here loads a model or touches the network: the polisher is asked
// about a file that is not there, or given a stand-in for llama.cpp.

@Suite(.timeLimit(.minutes(1))) struct S1MiniPromptTests {
    @Test func thePromptIsQwensChatFormatWithAnEmptyThinkBlock() {
        // What S1-mini's own chat template renders with enable_thinking=False,
        // taken from its tokenizer: the model was trained on exactly this.
        let prompt = S1MiniPolisher.promptPrefix + S1MiniPolisher.promptSuffix(for: "hello there")
        #expect(prompt == """
            <|im_start|>system
            \(S1MiniPolisher.systemPrompt)<|im_end|>
            <|im_start|>user
            [Styling: semi-formal] [Structure: lists] [Context: general]
            hello there<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """)
    }

    @Test func theSystemPromptIsTheModelCardsWordForWord() {
        #expect(S1MiniPolisher.systemPrompt.hasPrefix("You are a text normalizer for speech-to-text transcripts."))
        #expect(S1MiniPolisher.systemPrompt.hasSuffix("output only the cleaned text."))
    }

    @Test func longDictationsAreChunkedSmallerThanForApple() {
        let sentence = "One two three four five six seven eight nine ten."
        let text = Array(repeating: sentence, count: 50).joined(separator: " ")  // 500 words
        #expect(TranscriptPolisher.chunks(of: text).count == 1)
        let chunks = PolishChunking.chunks(
            of: text, threshold: S1MiniPolisher.chunkThreshold, size: S1MiniPolisher.chunkSize)
        #expect(chunks.count == 2)
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func eachModelNamesItsFile() {
        #expect(ModelFile(for: .appleIntelligence) == nil)
        #expect(ModelFile(for: .s1Mini) == .s1MiniFullPrecision)
        #expect(ModelFile(for: .s1Mini8Bit) == .s1Mini8Bit)
        // Pinned to a commit, never a branch.
        for file in [ModelFile.s1MiniFullPrecision, .s1Mini8Bit] {
            #expect(file.url.host() == "huggingface.co")
            #expect(!file.url.path().contains("/resolve/main/"))
            #expect(file.sha256.count == 64)
        }
    }

    @Test func withoutItsFileThePolisherPastesAsDictated() async {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".gguf")
        let polisher = S1MiniPolisher(file: .s1Mini8Bit, location: missing)
        await polisher.prepare()
        let report = await polisher.polish("hello there")
        #expect(report.text == nil)
        #expect(report.failure == "not downloaded")
        #expect(await polisher.refine("hello there") == nil)
    }
}

/// A loaded model that answers with `answer`, in place of llama.cpp.
private struct StandInModel: PromptCompleter {
    let answer: @Sendable (_ suffix: String) async throws -> String

    func complete(suffix: String, maxTokens: Int, deadline: ContinuousClock.Instant) async throws -> String {
        try await answer(suffix)
    }
}

@Suite(.timeLimit(.minutes(1))) struct S1MiniLoadTests {
    /// A polisher over a file that is there, loaded by `load`.
    private func polisher(
        timeout: Duration, load: @escaping S1MiniPolisher.Loader
    ) throws -> (S1MiniPolisher, URL) {
        let dir = try scratchDirectory("S1MiniLoadTests")
        let location = dir.appending(path: "model.gguf")
        try Data("weights".utf8).write(to: location)
        let polisher = S1MiniPolisher(
            file: .s1Mini8Bit, location: location, timeout: timeout, control: S1MiniPolisher.controlLine, load: load)
        return (polisher, dir)
    }

    // The first dictation after launch: the load (and on a first launch
    // Metal's shader compile) is still running when the budget runs out.
    // Before: the polish waited for the load however long it took, here the
    // gate's two seconds, and pasted late.
    @Test func aLoadPastTheBudgetPastesAsDictatedAndTheNextDictationGetsTheModel() async throws {
        let gate = Gate()
        let loads = Recorder<Int>()
        let (polisher, dir) = try polisher(timeout: .milliseconds(40)) { _, _ in
            loads.append(1)
            await gate.wait()
            return StandInModel { _ in "Send it on Friday." }
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let started = ContinuousClock.now
        let report = await polisher.polish("send it on friday")
        #expect(report.text == nil)
        #expect(report.failure == "still loading")
        #expect(ContinuousClock.now - started < .seconds(1))

        // The load carried on in the background; nothing restarted it.
        await gate.open()
        await polisher.prepare()
        #expect(await polisher.refine("send it on friday") == "Send it on Friday.")
        #expect(loads.all.count == 1)
    }

    @Test func anAnswerCutOffByTheTokenBudgetPastesAsDictated() async throws {
        let (polisher, dir) = try polisher(timeout: .seconds(5)) { _, _ in
            StandInModel { _ in throw LlamaModel.Failure.truncated }
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = await polisher.polish("send it on friday and copy anna")
        #expect(report.text == nil)
        #expect(report.failure == "answer cut off")
    }

    @Test func aLoadThatFailsPastesAsDictated() async throws {
        let (polisher, dir) = try polisher(timeout: .seconds(5)) { _, _ in throw LlamaModel.Failure.load }
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = await polisher.polish("send it on friday")
        #expect(report.text == nil)
        #expect(report.failure == "model did not load")
    }

    @Test func aLoadInterruptedByUnloadIsDropped() async throws {
        let gate = Gate()
        let loads = Recorder<Int>()
        let (polisher, dir) = try polisher(timeout: .milliseconds(40)) { _, _ in
            loads.append(1)
            let number = loads.all.count
            if number == 1 { await gate.wait() }
            return StandInModel { _ in number == 1 ? "First." : "Second." }
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await polisher.polish("send it")
        await polisher.unload()
        await gate.open()
        // Time for the first load to finish and try to store its model.
        // The right answer does not depend on it: either way the next call
        // starts a load of its own.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await polisher.refine("send it") == "Second.")
    }
}

@Suite(.timeLimit(.minutes(1))) struct LlamaGenerationTests {
    private let later = ContinuousClock.now + .seconds(60)

    /// Hands out `pieces` one per step, then `.end` when `ends`, and more
    /// text for as long as it is asked after that.
    private func steps(_ pieces: [String], ends: Bool) -> () -> LlamaModel.Step {
        var queue = pieces.map { LlamaModel.Step.piece(Array($0.utf8)) }
        if ends { queue.append(.end) }
        return { queue.isEmpty ? .piece(Array(" and more".utf8)) : queue.removeFirst() }
    }

    @Test func anAnswerThatEndsIsReturnedWhole() throws {
        let text = try LlamaModel.generate(limit: 10, deadline: later, next: steps(["Send", " it", " Friday."], ends: true))
        #expect(text == "Send it Friday.")
    }

    @Test func theEndMayBeTheLastStepTheLimitAllows() throws {
        let text = try LlamaModel.generate(limit: 4, deadline: later, next: steps(["Send", " it", " Friday."], ends: true))
        #expect(text == "Send it Friday.")
    }

    // Before: the loop stopped at the limit and returned "Send it Friday",
    // which was pasted with the rest of the dictation gone.
    @Test func anAnswerCutOffByTheLimitIsAFailureNotAShortAnswer() {
        #expect(throws: LlamaModel.Failure.truncated) {
            try LlamaModel.generate(limit: 3, deadline: later, next: steps(["Send", " it", " Friday", " and copy Anna."], ends: true))
        }
        #expect(throws: LlamaModel.Failure.truncated) {
            try LlamaModel.generate(limit: 8, deadline: later, next: steps(["Send"], ends: false))
        }
    }

    @Test func aCharacterSplitAcrossTwoPiecesIsDecodedWhole() throws {
        let umlaut = Array("ü".utf8)
        var queue: [LlamaModel.Step] = [.piece(Array("gr".utf8) + [umlaut[0]]), .piece([umlaut[1]] + Array("n".utf8)), .end]
        let text = try LlamaModel.generate(limit: 5, deadline: later) { queue.removeFirst() }
        #expect(text == "grün")
    }

    @Test func pastTheDeadlineIsATimeout() {
        #expect(throws: LlamaModel.Failure.timedOut) {
            try LlamaModel.generate(limit: 5, deadline: .now - .seconds(1), next: steps(["Send"], ends: true))
        }
    }
}
