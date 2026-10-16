import Testing
@testable import PladderCore

@Suite struct GenerationTests {
    @Test func eachNextIsCurrentUntilTheOneAfter() {
        var generation = Generation()
        let first = generation.next()
        #expect(generation.isCurrent(first))
        let second = generation.next()
        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
        #expect(generation.current == second)
    }

    @Test func nothingIsCurrentBeforeTheFirstNext() {
        let generation = Generation()
        #expect(!generation.isCurrent(1))
        #expect(generation.current == 0)
    }
}
