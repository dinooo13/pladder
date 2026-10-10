import Dispatch
import Testing
@testable import PladderCore

@Suite struct CustomWordCorrectorTests {
    private func corrector(_ terms: [String]) -> CustomWordCorrector {
        CustomWordCorrector(entries: terms.map { DictionaryEntry(from: "", to: $0) })
    }

    @Test func spelledOutAcronym() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "Chat G P T") == "ChatGPT")
        #expect(c.apply(to: "ask chat g p t about it") == "ask ChatGPT about it")
    }

    @Test func splitBrandName() {
        let c = corrector(["ChargeBee"])
        #expect(c.apply(to: "Charge B") == "ChargeBee")
        #expect(c.apply(to: "the charge b invoice") == "the ChargeBee invoice")
    }

    @Test func ampersandSpelledOut() {
        let c = corrector(["R&D"])
        #expect(c.apply(to: "R and D") == "R&D")
        #expect(c.apply(to: "the r and d budget") == "the R&D budget")
    }

    @Test func shortWordsOnlyMatchExactly() {
        let c = corrector(["Tee", "TS"])
        #expect(c.apply(to: "the") == "the")
        #expect(c.apply(to: "the cat sat on the mat") == "the cat sat on the mat")
        #expect(c.apply(to: "a tee shirt") == "a Tee shirt")
    }

    @Test func aLongTermDoesNotSwallowAnUnrelatedPhrase() {
        let c = corrector(["Kubernetes"])
        #expect(c.apply(to: "the number of times") == "the number of times")
        #expect(c.apply(to: "kubernetties is hard") == "Kubernetes is hard")
    }

    @Test func trailingPunctuationIsPreserved() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "use Chat G P T, then") == "use ChatGPT, then")
        #expect(c.apply(to: "use chat g p t.") == "use ChatGPT.")
    }

    @Test func surroundingPunctuationIsPreserved() {
        let c = corrector(["ChargeBee"])
        #expect(c.apply(to: "(charge b)") == "(ChargeBee)")
        #expect(c.apply(to: "\u{201c}charge b\u{201d} again") == "\u{201c}ChargeBee\u{201d} again")
    }

    @Test func anNGramNeverCrossesAComma() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "chat, g p t") == "chat, g p t")
        #expect(c.apply(to: "chat g, p t") == "chat g, p t")
    }

    @Test func whitespaceOutsideMatchesIsUntouched() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "Chat G P T\n\nis great") == "ChatGPT\n\nis great")
        #expect(c.apply(to: "  chat g p t  ") == "  ChatGPT  ")
    }

    @Test func aLowercaseTermMirrorsTheMatchedCase() {
        let c = corrector(["dotnet"])
        #expect(c.apply(to: "dot net") == "dotnet")
        #expect(c.apply(to: "Dot net") == "Dotnet")
        #expect(c.apply(to: "DOT NET") == "DOTNET")
    }

    @Test func aTermWithItsOwnCapitalsIsVerbatim() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "chat g p t") == "ChatGPT")
        #expect(c.apply(to: "CHAT G P T") == "ChatGPT")
    }

    @Test func aSingleUppercaseLetterIsNotAllCaps() {
        let c = corrector(["dotnet"])
        #expect(c.apply(to: "D ot net") == "Dotnet")
    }

    @Test func anAlreadyCorrectWordIsUnchanged() {
        let c = corrector(["ChatGPT", "ChargeBee"])
        #expect(c.apply(to: "I use ChatGPT and ChargeBee daily") == "I use ChatGPT and ChargeBee daily")
    }

    @Test func textThatNeedsNothingIsReturnedIdentically() {
        let c = corrector(["ChatGPT", "ChargeBee", "Kubernetes"])
        let input = "the meeting moved to Thursday, so nobody has to travel"
        #expect(c.apply(to: input) == input)
    }

    @Test func anEmptyTermListReturnsTheInput() {
        let c = corrector([])
        #expect(c.apply(to: "chat g p t") == "chat g p t")
        #expect(c.apply(to: "") == "")
    }

    @Test func entriesWithAHeardAsValueAreNotTerms() {
        let c = CustomWordCorrector(entries: [DictionaryEntry(from: "chat gpt", to: "ChatGPT")])
        #expect(c.apply(to: "Chat G P T") == "Chat G P T")
    }

    @Test func blankTermsAreIgnored() {
        let c = CustomWordCorrector(entries: [
            DictionaryEntry(from: "  ", to: "   "),
            DictionaryEntry(from: "", to: "!!!"),
        ])
        #expect(c.apply(to: "chat g p t") == "chat g p t")
    }

    @Test func aNonASCIITermIsSkipped() {
        let c = corrector(["Müller", "Grüße"])
        #expect(c.apply(to: "muller said hello") == "muller said hello")
        #expect(c.apply(to: "Müller said hello") == "Müller said hello")
    }

    @Test func nonASCIITranscriptTextIsLeftAlone() {
        let c = corrector(["ChatGPT"])
        #expect(c.apply(to: "grüße aus München") == "grüße aus München")
        #expect(c.apply(to: "chat g p t, grüße") == "ChatGPT, grüße")
    }

    @Test func aPossessiveSuffixIsNotSwallowed() {
        let c = corrector(["Claude", "ChatGPT"])
        #expect(c.apply(to: "ask Claude's opinion") == "ask Claude's opinion")
        #expect(c.apply(to: "ChatGPT's answer") == "ChatGPT's answer")
    }

    @Test func aMisheardWordKeepsItsPossessive() {
        let c = corrector(["Claude"])
        #expect(c.apply(to: "clawed's opinion") == "Claude's opinion")
    }

    @Test func aCurlyApostropheIsAPossessiveToo() {
        let c = corrector(["Claude"])
        #expect(c.apply(to: "ask Claude\u{2019}s opinion") == "ask Claude\u{2019}s opinion")
        #expect(c.apply(to: "clawed\u{2019}s opinion") == "Claude\u{2019}s opinion")
    }

    @Test func aTermThatIsItselfAPossessiveIsNotDoubled() {
        let c = corrector(["McDonald's"])
        #expect(c.apply(to: "McDonald's") == "McDonald's")
        #expect(c.apply(to: "mcdonald's fries") == "McDonald's fries")
    }

    @Test func soundexRescuesAHomophoneTheDistanceAloneWouldReject() {
        let c = corrector(["ChargeBee"])
        // "chargeb" is two edits from "chargebee": 2/9 = 0.22, over the threshold until the
        // matching Soundex code scales it down.
        #expect(c.apply(to: "charge b") == "ChargeBee")
    }

    @Test func anOrdinaryWordIsNotRewrittenIntoATerm() {
        let c = corrector(["Claude", "Swift", "Rust"])
        #expect(c.apply(to: "to the cloud") == "to the cloud")
        #expect(c.apply(to: "press shift") == "press shift")
        #expect(c.apply(to: "take a rest") == "take a rest")
        #expect(c.apply(to: "the roast") == "the roast")
    }

    @Test func soundexExcusesOneEditAtMostOnAShortKey() {
        let c = CustomWordCorrector(entries: [DictionaryEntry(from: "", to: "Rust")], isOrdinaryWord: { _ in false })
        #expect(c.apply(to: "the roast") == "the roast")
        #expect(c.apply(to: "the rost") == "the Rust")
    }

    @Test func aLongerCandidateDoesNotLiftTheShortKeyCap() {
        let c = CustomWordCorrector(entries: [DictionaryEntry(from: "", to: "Swift")], isOrdinaryWord: { _ in false })
        #expect(c.apply(to: "the soviet union") == "the soviet union")
        #expect(c.apply(to: "the swifft code") == "the Swift code")
    }

    @Test func theLexiconIsWhatKeepsALongerOrdinaryWord() {
        let terms = [DictionaryEntry(from: "", to: "Claude")]
        let open = CustomWordCorrector(entries: terms, isOrdinaryWord: { _ in false })
        #expect(open.apply(to: "to the cloud") == "to the Claude")
        let strict = CustomWordCorrector(entries: terms, isOrdinaryWord: { $0 == "clawed" })
        #expect(strict.apply(to: "clawed's opinion") == "clawed's opinion")
        #expect(strict.apply(to: "to the cloud") == "to the Claude")
    }

    @Test func aNearMissThatIsNoWordIsStillRepaired() {
        let c = corrector(["Kafka", "Claude"])
        #expect(c.apply(to: "send it to kafca") == "send it to Kafka")
        #expect(c.apply(to: "ask clawed") == "ask Claude")
    }

    @Test func anOrdinaryWordStillTakesTheTermOnAnExactKey() {
        let c = corrector(["Swift"])
        #expect(c.apply(to: "write it in swift") == "write it in Swift")
    }

    @Test func aSpelledOutTermMadeOfOrdinaryWordsIsStillRepaired() {
        let c = corrector(["Claude Code"])
        #expect(c.apply(to: "open cloud code") == "open Claude Code")
    }

    // Not an assertion: the release path's price tag, printed so a change that makes this
    // processor expensive shows in the test log. `swift test -c release` for the real number.
    @Test func costOfOneHundredWordsAgainstFiftyTerms() {
        let c = corrector(Self.fiftyTerms)
        let transcript = Self.hundredWordTranscript
        #expect(transcript.split(separator: " ").count == 100)

        #if DEBUG
        let iterations = 11
        #else
        let iterations = 1_000
        #endif

        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        var sink = 0
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            let out = c.apply(to: transcript)
            samples.append(DispatchTime.now().uptimeNanoseconds - start)
            sink &+= out.utf8.count
        }
        #expect(sink > 0)
        samples.sort()
        let median = Double(samples[samples.count / 2]) / 1_000
        print("CustomWordCorrector cost: median \(String(format: "%.1f", median)) µs "
            + "for 100 words against \(Self.fiftyTerms.count) terms")
    }

    private static let fiftyTerms = [
        "ChatGPT", "ChargeBee", "R&D", "Kubernetes", "kubectl",
        "PostgreSQL", "GraphQL", "TypeScript", "JavaScript", "Xcode",
        "SwiftUI", "CoreML", "FluidAudio", "Parakeet", "Anthropic",
        "Claude Code", "GitHub", "GitLab", "Bitbucket", "Terraform",
        "Kubeflow", "Grafana", "Prometheus", "Datadog", "PagerDuty",
        "Sentry", "Redis", "MongoDB", "DynamoDB", "Cassandra",
        "RabbitMQ", "Kafka", "Elasticsearch", "OpenSearch", "Nginx",
        "Envoy", "Istio", "Helm", "Argo CD", "Jenkins",
        "CircleCI", "Snowflake", "Databricks", "Airflow", "dbt",
        "Looker", "Tableau", "Figma", "Notion", "Linear",
    ]

    private static let hundredWordTranscript = """
        this morning I pushed the branch to get hub and asked chat g p t to \
        review the migration before we run it against the postgres cluster \
        because the last one locked a table for nine minutes and the on call \
        engineer had to page the whole team at two in the morning which is \
        exactly the kind of thing we said we would stop doing after the \
        retro so please add a dashboard panel for the queue depth and wire \
        an alert to the usual channel and then write it up in the weekly \
        note so everyone sees it
        """
}
