import Testing
@testable import PladderCore

@Suite struct FillerRemoverTests {
    private func run(
        _ text: String,
        hint: (@Sendable (String) -> String?)? = nil
    ) async throws -> String {
        try await FillerRemover(languageHint: hint).process(text)
    }

    // MARK: Real words that must survive without language evidence

    @Test func preservesGermanUmAndSpanishEhAndUnitMillimetres() async throws {
        // "um" is a German preposition ("at eight o'clock"), "eh" is a
        // German colloquialism ("doesn't matter anyway"), and "mm" is the
        // unit millimetre. None of the three is a filler here, and none has
        // language evidence attached, so the fail-closed universal tier
        // must leave all of them alone.
        #expect(try await run("um acht Uhr sind wir da") == "um acht Uhr sind wir da")
        #expect(try await run("das ist eh egal") == "das ist eh egal")
        #expect(try await run("5 mm lang") == "5 mm lang")
    }

    @Test func aGermanHintStillLeavesGermanUmAndEhAlone() async throws {
        // The German gated tier adds nothing on top of the universal one:
        // bare "um" and "eh" are real German words, not fillers, regardless
        // of the language hint.
        #expect(try await run("um acht Uhr sind wir da", hint: { _ in "de" }) == "um acht Uhr sind wir da")
        #expect(try await run("das ist eh egal", hint: { _ in "de" }) == "das ist eh egal")
        #expect(try await run("5 mm lang", hint: { _ in "de" }) == "5 mm lang")
    }

    // MARK: Universal tier — always removed, no hint needed

    @Test func removesUniversalFillers() async throws {
        let result = try await run(
            "so i think we should ship this on uh friday")
        #expect(result == "so i think we should ship this on friday")
    }

    @Test func capitalisesAfterLeadingUniversalFiller() async throws {
        #expect(try await run("Umm, i'll be there soon") == "I'll be there soon")
    }

    @Test func consumesNeighbouringCommasForUniversalFillers() async throws {
        #expect(try await run("we could, uh, ship it") == "we could ship it")
    }

    @Test func removesGermanUniversalFillers() async throws {
        #expect(try await run("ähm ich think nothing") == "Ich think nothing")
        #expect(try await run("Ähm, das ist gut") == "Das ist gut")
        #expect(try await run("sofort äh später") == "sofort später")
    }

    @Test func coversElongatedForms() async throws {
        #expect(try await run("uhh i am not sure") == "I am not sure")
        #expect(try await run("ummm that works") == "That works")
        #expect(try await run("ähmm mal sehen") == "Mal sehen")
    }

    @Test func leavesContentWordsAlone() async throws {
        let text = "The summer was warm around Berlin, I am sure"
        #expect(try await run(text) == text)
        #expect(try await run("say hello to erm children") == "say hello to children")
    }

    @Test func leavesNonHesitantWordsAlone() async throws {
        #expect(try await run("you know, like, I mean, eigentlich, pues") == "you know, like, I mean, eigentlich, pues")
    }

    @Test func allUniversalFillerInputCollapsesToEmpty() async throws {
        #expect(try await run("erm... hm, ahm.") == "")
    }

    @Test func emptyInputIsReturnedUnchanged() async throws {
        #expect(try await run("") == "")
        #expect(try await run("clean already") == "clean already")
    }

    // MARK: Gated tier — only removed with matching language evidence

    @Test func gatedEnglishFillerNeedsAnEnglishHint() async throws {
        #expect(try await run("um the meeting is at three", hint: { _ in "en" }) == "The meeting is at three")
        #expect(try await run("um the meeting is at three") == "um the meeting is at three")
    }

    @Test func removesGatedEnglishFillersWithHint() async throws {
        let result = try await run(
            "um so i think we should ship this on uh friday", hint: { _ in "en" })
        #expect(result == "So i think we should ship this on friday")
        #expect(try await run("I, um, think it's ready", hint: { _ in "en" }) == "I think it's ready")
        #expect(try await run("ah well, that works", hint: { _ in "en" }) == "Well, that works")
        #expect(try await run("ah well, that works") == "ah well, that works")
    }

    @Test func doesNotTreatGermanPronounErAsAnEnglishFiller() async throws {
        // "er" is deliberately excluded from the English gated tier: it is
        // the German pronoun "he", and a language guess is never proof.
        #expect(try await run("er said he would come", hint: { _ in "en" }) == "er said he would come")
    }

    @Test func gatedSpanishFillerNeedsASpanishHint() async throws {
        #expect(try await run("eh no sé", hint: { _ in "es" }) == "No sé")
        #expect(try await run("eh no sé") == "eh no sé")
        #expect(try await run("pues eh, mira", hint: { _ in "es" }) == "pues mira")
    }

    @Test func allGatedFillerInputCollapsesToEmptyWithHint() async throws {
        #expect(try await run("um... uh, um.", hint: { _ in "en" }) == "")
        #expect(try await run("um... uh, um.") == "um... um.")
    }

    @Test func languageHintIsOnlyCalledWhenAGatedTokenIsPresent() async throws {
        let counter = CallCounter()
        let hint: @Sendable (String) -> String? = { _ in
            counter.count += 1
            return "en"
        }
        _ = try await run("we could, uh, ship it", hint: hint)
        #expect(counter.count == 0)
        _ = try await run("um the meeting is at three", hint: hint)
        #expect(counter.count == 1)
    }
}

/// A mutable counter, used to assert how many times the language hint
/// closure fired. Test-only, single-threaded call sites, so `@unchecked`
/// is safe here.
private final class CallCounter: @unchecked Sendable {
    var count = 0
}
