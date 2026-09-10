import Foundation
import Testing
@testable import SpeakUpCore

/// Stands in for a cleanup backend: returns its input, so a pipeline built
/// around it is easy to assert on.
private struct StubProcessor: TextProcessor {
    let id: String
    let displayName: String
    let detail = ""
    func process(_ text: String) async throws -> String { text }
}

private func entry(
    id: String,
    displayName: String = "Stub",
    reason: String? = nil
) -> CleanupRegistry.Entry {
    CleanupRegistry.Entry(
        id: id,
        displayName: displayName,
        detail: "",
        availability: { reason },
        make: { StubProcessor(id: id, displayName: displayName) }
    )
}

private func settings(enabled: Bool, provider: String) -> Settings {
    var s = Settings(engineID: EchoEngine.engineID)
    s.cleanupEnabled = enabled
    s.cleanupProviderID = provider
    return s
}

@Suite struct CleanupRegistryTests {
    @Test func registerReplacesSameID() {
        var registry = CleanupRegistry([entry(id: "a", displayName: "First")])
        registry.register(entry(id: "b", displayName: "Other"))
        registry.register(entry(id: "a", displayName: "Second"))
        #expect(registry.available.count == 2)
        #expect(registry.entry(for: "a")?.displayName == "Second")
        #expect(registry.available.map(\.id) == ["a", "b"])
    }

    @Test func makeProcessorNilWhenDisabled() {
        let registry = CleanupRegistry([entry(id: "a")])
        #expect(registry.makeProcessor(for: settings(enabled: false, provider: "a")) == nil)
    }

    @Test func makeProcessorNilWhenUnknownID() {
        let registry = CleanupRegistry([entry(id: "a")])
        #expect(registry.makeProcessor(for: settings(enabled: true, provider: "nope")) == nil)
    }

    @Test func makeProcessorNilWhenUnavailable() {
        let registry = CleanupRegistry([entry(id: "a", reason: "Apple Intelligence is off")])
        #expect(registry.makeProcessor(for: settings(enabled: true, provider: "a")) == nil)
    }

    @Test func makeProcessorReturnsProcessorWhenEnabledAndAvailable() {
        let registry = CleanupRegistry([entry(id: "a")])
        #expect(registry.makeProcessor(for: settings(enabled: true, provider: "a"))?.id == "a")
    }

    @Test func standardPipelineOrderWithCleanup() {
        let registry = CleanupRegistry([entry(id: "a")])
        let pipeline = ProcessorPipeline.standard(
            settings: settings(enabled: true, provider: "a"), cleanup: registry)
        #expect(pipeline.processors.map(\.id) == [
            DictionaryReplacer.processorID, "a", WhitespaceNormalizer.processorID,
        ])
    }

    @Test func standardPipelineOrderWithoutCleanup() {
        let registry = CleanupRegistry([entry(id: "a")])
        let pipeline = ProcessorPipeline.standard(
            settings: settings(enabled: false, provider: "a"), cleanup: registry)
        #expect(pipeline.processors.map(\.id) == [
            DictionaryReplacer.processorID, WhitespaceNormalizer.processorID,
        ])
    }
}
