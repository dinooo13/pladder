import Testing
@testable import PladderCore

@Suite struct DictionaryEntryTests {
    @Test func twoRuleCycleIsFlagged() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "a")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b]) == [a.id, b.id])
    }

    @Test func threeRuleCycleIsFlagged() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "c")
        let c = DictionaryEntry(from: "c", to: "a")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b, c]) == [a.id, b.id, c.id])
    }

    @Test func selfReferenceIsNotACycle() {
        // Each rule runs once, so a replacement that contains its own
        // trigger is applied once and never revisited.
        let expand = DictionaryEntry(from: "claude", to: "Claude Code")
        let recase = DictionaryEntry(from: "iphone", to: "iPhone")
        #expect(DictionaryEntry.cyclicIDs(in: [expand, recase]).isEmpty)
        #expect(DictionaryReplacer(entries: [expand]).apply(to: "ask claude") == "ask Claude Code")
    }

    @Test func aChainIsNotACycle() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "c")
        let c = DictionaryEntry(from: "c", to: "d")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b, c]).isEmpty)
    }

    @Test func unrelatedRulesAreUntouched() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "a")
        let unrelated = DictionaryEntry(from: "claude code", to: "Claude Code")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b, unrelated]) == [a.id, b.id])
    }

    @Test func matchingIsWholeWordAndCaseInsensitive() {
        // "cab" contains "a" and "b" as substrings but not as whole words,
        // so it must not create a spurious edge.
        let a = DictionaryEntry(from: "a", to: "cab")
        let b = DictionaryEntry(from: "b", to: "A")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b]).isEmpty)
    }

    @Test func dictionaryReplacerSkipsCyclicEntries() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "a")
        let unrelated = DictionaryEntry(from: "claude code", to: "Claude Code")
        let replacer = DictionaryReplacer(entries: [a, b, unrelated])
        // The cyclic pair is dropped entirely; the unrelated rule still runs.
        #expect(replacer.apply(to: "a b claude code") == "a b Claude Code")
    }
}
