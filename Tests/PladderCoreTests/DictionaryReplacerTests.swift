import Testing
@testable import PladderCore

@Suite struct DictionaryReplacerTests {
    private func replacer(_ pairs: [(String, String)], matchCase: Bool = false) -> DictionaryReplacer {
        DictionaryReplacer(entries: pairs.map { DictionaryEntry(from: $0.0, to: $0.1, matchCase: matchCase) })
    }

    @Test func wholeWordOnly() {
        let r = replacer([("cat", "dog")])
        #expect(r.apply(to: "the cat sat") == "the dog sat")
        #expect(r.apply(to: "concatenate") == "concatenate")
    }

    @Test func caseInsensitiveByDefault() {
        let r = replacer([("claude", "Claude")])
        #expect(r.apply(to: "ask CLAUDE about it") == "ask Claude about it")
    }

    @Test func multiWordAndLongestFirst() {
        let r = replacer([("claude", "Claude"), ("claude code", "Claude Code")])
        #expect(r.apply(to: "open claude code and ask claude") == "open Claude Code and ask Claude")
        #expect(r.apply(to: "open claude   code") == "open Claude Code")
    }

    @Test func sentenceStartCapitalisation() {
        let r = replacer([("grpc", "grpc")])
        #expect(r.apply(to: "Grpc is fast. use grpc.") == "Grpc is fast. use grpc.")
        let brand = replacer([("iphone", "iPhone")])
        #expect(brand.apply(to: "Iphone rocks") == "iPhone rocks")
        let lower = replacer([("dot net", "dotnet")])
        #expect(lower.apply(to: "Dot net is ok") == "Dotnet is ok")
    }

    @Test func matchCaseRespected() {
        let r = replacer([("US", "United States")], matchCase: true)
        #expect(r.apply(to: "the US and us") == "the United States and us")
    }

    @Test func punctuationEdges() {
        let r = replacer([("c++", "C++")])
        #expect(r.apply(to: "i like c++ a lot") == "i like C++ a lot")
        #expect(r.apply(to: "(c++)") == "(c++)")
    }

    @Test func emptyEntriesIgnored() {
        let r = replacer([("", "x"), ("  ", "y")])
        #expect(r.apply(to: "nothing changes") == "nothing changes")
    }

    // MARK: Unicode word boundaries

    @Test func umlautEdgeIsAWordBoundary() {
        let r = replacer([("ärger", "Ärger")])
        #expect(r.apply(to: "das ist ärger") == "das ist Ärger")
    }

    @Test func umlautAtTheEndOfFromIsAWordBoundary() {
        let r = replacer([("müde", "erschöpft")])
        #expect(r.apply(to: "ich bin müde heute") == "ich bin erschöpft heute")
    }

    @Test func accentedEntryMatchesNextToPunctuation() {
        let r = replacer([("cafe", "café")])
        #expect(r.apply(to: "the cafe, is nice") == "the café, is nice")
        let capitalized = replacer([("café", "Café")])
        #expect(capitalized.apply(to: "(café)") == "(Café)")
    }

    @Test func cjkEntryMatchesWithoutSpaces() {
        let r = replacer([("東京", "Tokyo")])
        #expect(r.apply(to: "私は東京に行く") == "私はTokyoに行く")
    }
}
