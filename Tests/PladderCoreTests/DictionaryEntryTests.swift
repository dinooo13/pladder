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
        let a = DictionaryEntry(from: "a", to: "cab")
        let b = DictionaryEntry(from: "b", to: "A")
        #expect(DictionaryEntry.cyclicIDs(in: [a, b]).isEmpty)
    }

    @Test func dictionaryReplacerSkipsCyclicEntries() {
        let a = DictionaryEntry(from: "a", to: "b")
        let b = DictionaryEntry(from: "b", to: "a")
        let unrelated = DictionaryEntry(from: "claude code", to: "Claude Code")
        let replacer = DictionaryReplacer(entries: [a, b, unrelated])
        #expect(replacer.apply(to: "a b claude code") == "a b Claude Code")
    }
}

@Suite struct DictionaryMergeTests {
    @Test func aRuleWithTheSameHeardAsOverwritesAndKeepsItsID() {
        let existing = DictionaryEntry(from: " Clode Code ", to: "claude code", matchCase: true)
        var entries = [existing]
        entries.merge([DictionaryEntry(from: "clode code", to: "Claude Code")])
        #expect(entries.count == 1)
        #expect(entries[0].id == existing.id)
        #expect(entries[0].to == "Claude Code")
        #expect(entries[0].matchCase == false)
    }

    @Test func aCustomWordIsKeyedByItsReplacement() {
        var entries = [DictionaryEntry(from: "", to: "Pladder")]
        entries.merge([DictionaryEntry(from: "", to: "pladder "), DictionaryEntry(from: "", to: "Parakeet")])
        #expect(entries.map(\.to) == ["pladder ", "Parakeet"])
    }

    @Test func aRowWithNeitherSideIsSkipped() {
        var entries: [DictionaryEntry] = []
        entries.merge([DictionaryEntry(from: "  ", to: "")])
        #expect(entries.isEmpty)
    }

    @Test func duplicatesWithinOneImportCollapse() {
        var entries: [DictionaryEntry] = []
        entries.merge([DictionaryEntry(from: "a", to: "b"), DictionaryEntry(from: "A", to: "c")])
        #expect(entries.map(\.to) == ["c"])
    }

    @Test func hasRuleIgnoresCaseAndSpacesButNotCustomWords() {
        let entries = [DictionaryEntry(from: " Swift UI", to: "SwiftUI"), DictionaryEntry(from: "", to: "Pladder")]
        #expect(entries.hasRule(for: "swift ui"))
        #expect(!entries.hasRule(for: "pladder"))
        #expect(!entries.hasRule(for: " "))
    }
}

@Suite struct DurationTimeIntervalTests {
    @Test func secondsAndFractionsSurvive() {
        #expect(Duration.seconds(2).timeInterval == 2)
        #expect(abs(Duration.milliseconds(1_500).timeInterval - 1.5) < 1e-12)
        #expect(Duration.zero.timeInterval == 0)
    }
}
