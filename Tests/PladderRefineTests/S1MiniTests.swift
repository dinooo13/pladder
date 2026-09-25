import Foundation
import PladderCore
import Testing
@testable import PladderRefine

// Nothing here loads a model or touches the network: the downloads come from
// a file URL, and the polisher is asked about a file that is not there.

@Suite struct S1MiniPromptTests {
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
        let chunks = TranscriptPolisher.chunks(
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

@Suite struct ModelFilesTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ModelFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func source(in dir: URL, contents: String) throws -> URL {
        let url = dir.appending(path: "source.bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func aDownloadThatMatchesItsChecksumBecomesReady() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModelFile(
            fileName: "model.gguf", url: try source(in: dir, contents: "weights"),
            // SHA-256 of "weights".
            sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c",
            byteCount: 7)
        let files = ModelFiles(directory: dir.appending(path: "models"))
        #expect(await files.status(of: file) == .missing)
        await files.ensure(file)
        #expect(await files.finished(file) == .ready)
        #expect(try String(contentsOf: files.location(of: file), encoding: .utf8) == "weights")
    }

    @Test func aDownloadThatDoesNotMatchIsDeletedAndNeverUsed() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModelFile(
            fileName: "model.gguf", url: try source(in: dir, contents: "tampered"),
            sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c",
            byteCount: 8)
        let models = dir.appending(path: "models")
        let files = ModelFiles(directory: models)
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.checksum))
        #expect(!FileManager.default.fileExists(atPath: files.location(of: file).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func aMissingSourceFailsAsADownload() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModelFile(
            fileName: "model.gguf", url: dir.appending(path: "nowhere.bin"),
            sha256: String(repeating: "0", count: 64), byteCount: 1)
        let files = ModelFiles(directory: dir.appending(path: "models"))
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.download))
    }
}
