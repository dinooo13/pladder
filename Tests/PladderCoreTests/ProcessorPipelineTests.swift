import Testing
@testable import PladderCore

private struct UppercaseProcessor: TextProcessor {
    let id = "uppercase"
    func process(_ text: String) -> String { text.uppercased() }
}

private struct AppendingProcessor: TextProcessor {
    let id: String
    let suffix: String
    func process(_ text: String) -> String { text + suffix }
}

@Suite struct ProcessorPipelineTests {
    @Test func runsProcessorsInOrder() {
        let pipeline = ProcessorPipeline([
            AppendingProcessor(id: "a", suffix: "-a"),
            AppendingProcessor(id: "b", suffix: "-b"),
        ])
        #expect(pipeline.run("x") == "x-a-b")
    }

    @Test func skipsDisabledProcessors() {
        let pipeline = ProcessorPipeline([UppercaseProcessor(), AppendingProcessor(id: "a", suffix: "!")])
        #expect(pipeline.run("hi", disabled: ["uppercase"]) == "hi!")
    }

    @Test func anEmptyPipelinePassesTheTextThrough() {
        #expect(ProcessorPipeline([]).run("as dictated") == "as dictated")
    }
}
