import Dispatch
import Testing
@testable import PladderCore

@Suite struct CustomWordCorrectorTests {
    /// Terms are dictionary entries with an empty `from`, exactly as the
    /// Dictionary tab stores them.
    private func corrector(_ terms: [String]) -> CustomWordCorrector {
        CustomWordCorrector(entries: terms.map { DictionaryEntry(from: "", to: $0) })
    }

    // MARK: The three examples from the issue

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

    // MARK: False positives

    @Test func shortWordsOnlyMatchExactly() {
        let c = corrector(["Tee", "TS"])
        #expect(c.apply(to: "the") == "the")
        #expect(c.apply(to: "the cat sat on the mat") == "the cat sat on the mat")
        // The exact key still matches, so the terms are not dead weight.
        #expect(c.apply(to: "a tee shirt") == "a Tee shirt")
    }

    @Test func aLongTermDoesNotSwallowAnUnrelatedPhrase() {
        let c = corrector(["Kubernetes"])
        #expect(c.apply(to: "the number of times") == "the number of times")
        #expect(c.apply(to: "kubernetties is hard") == "Kubernetes is hard")
    }

    // MARK: Punctuation

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

    // MARK: Case

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
        // One letter is ambiguous, so it counts as capitalised, not as caps.
        let c = corrector(["dotnet"])
        #expect(c.apply(to: "D ot net") == "Dotnet")
    }

    // MARK: Nothing to do

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
        // Those belong to DictionaryReplacer; this processor must ignore them.
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

    // MARK: Non-ASCII

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

    // MARK: Soundex

    @Test func soundexRescuesAHomophoneTheDistanceAloneWouldReject() {
        let c = corrector(["ChargeBee"])
        // "chargeb" is two edits from "chargebee": 2/9 = 0.22, over the
        // threshold until the matching Soundex code scales it down.
        #expect(c.apply(to: "charge b") == "ChargeBee")
    }

    // MARK: Cost

    /// Not an assertion — the release-to-paste path's price tag, printed so a
    /// change that makes this processor expensive is visible in the test log.
    /// Run with `swift test -c release` for the number that matters; a debug
    /// build is two orders of magnitude slower and takes a short sample so the
    /// suite still finishes in well under a second.
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
