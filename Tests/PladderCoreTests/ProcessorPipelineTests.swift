import Testing
@testable import PladderCore

private struct UppercaseProcessor: TextProcessor {
    let id = "uppercase"
    let displayName = "Uppercase"
    let detail = ""
    func process(_ text: String) async throws -> String { text.uppercased() }
}

private struct AppendingProcessor: TextProcessor {
    let id: String
    let suffix: String
    var displayName: String { id }
    let detail = ""
    func process(_ text: String) async throws -> String { text + suffix }
}

private struct ThrowingProcessor: TextProcessor {
    struct Failure: Error {}
    let id = "boom"
    let displayName = "Boom"
    let detail = ""
    func process(_ text: String) async throws -> String { throw Failure() }
}

@Suite struct ProcessorPipelineTests {
    @Test func runsProcessorsInOrder() async {
        let pipeline = ProcessorPipeline([
            AppendingProcessor(id: "a", suffix: "-a"),
            AppendingProcessor(id: "b", suffix: "-b"),
        ])
        #expect(await pipeline.run("x") == "x-a-b")
    }

    @Test func skipsDisabledProcessors() async {
        let pipeline = ProcessorPipeline([UppercaseProcessor(), AppendingProcessor(id: "a", suffix: "!")])
        #expect(await pipeline.run("hi", disabled: ["uppercase"]) == "hi!")
    }

    @Test func aThrowingProcessorIsSkippedAndTheRestStillRun() async {
        // A throw used to propagate out of `run` and lose the whole
        // dictation. It should instead be skipped in place, with the text
        // from the previous stage carried on to the processors after it.
        let pipeline = ProcessorPipeline([
            AppendingProcessor(id: "before", suffix: "-before"),
            ThrowingProcessor(),
            AppendingProcessor(id: "after", suffix: "-after"),
        ])
        #expect(await pipeline.run("x") == "x-before-after")
    }

    @Test func reportsWhichProcessorFailed() async {
        let recorded = FailureRecorder()
        let pipeline = ProcessorPipeline(
            [AppendingProcessor(id: "before", suffix: "-before"), ThrowingProcessor()],
            onFailure: { id, error in
                recorded.id = id
                recorded.sawError = error is ThrowingProcessor.Failure
            }
        )
        _ = await pipeline.run("x")
        #expect(recorded.id == "boom")
        #expect(recorded.sawError == true)
    }
}

/// Captures the arguments `onFailure` was called with. Single-threaded call
/// site (the pipeline calls it inline before `run` returns), so `@unchecked`
/// is safe here.
private final class FailureRecorder: @unchecked Sendable {
    var id: String?
    var sawError = false
}
