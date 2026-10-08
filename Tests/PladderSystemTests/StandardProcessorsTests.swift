import Testing
import PladderCore
@testable import PladderSystem

@Suite struct StandardProcessorsTests {
    @Test func eachEntryNamesTheProcessorItBuilds() {
        let settings = DictationSettings(engineID: EngineID("e"))
        #expect(StandardProcessors.entries.map { $0.make(settings).id } == StandardProcessors.entries.map(\.id))
    }

    @Test func idsAreUnique() {
        let ids = StandardProcessors.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
