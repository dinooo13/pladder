import Testing
@testable import PladderCore

@Suite struct FillerRemoverTests {
    private func run(_ text: String) async throws -> String {
        try await FillerRemover().process(text)
    }

    @Test func removesEnglishFillers() async throws {
        let result = try await run(
            "um so i think we should ship this on uh friday")
        #expect(result == "So i think we should ship this on friday")
    }

    @Test func capitalisesAfterLeadingFiller() async throws {
        #expect(try await run("um the meeting is at three") == "The meeting is at three")
        #expect(try await run("Umm, i'll be there soon") == "I'll be there soon")
    }

    @Test func consumesNeighbouringCommas() async throws {
        #expect(try await run("I, um, think it's ready") == "I think it's ready")
        #expect(try await run("we could, uh, ship it") == "we could ship it")
    }

    @Test func removesGermanFillers() async throws {
        #expect(try await run("ähm ich think nothing") == "Ich think nothing")
        #expect(try await run("Ähm, das ist gut") == "Das ist gut")
        #expect(try await run("sofort äh später") == "sofort später")
    }

    @Test func removesSpanishFillers() async throws {
        #expect(try await run("eh no sé") == "No sé")
        #expect(try await run("pues em, mira") == "pues mira")
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

    @Test func allFillerInputCollapsesToEmpty() async throws {
        #expect(try await run("um... uh, um.") == "")
    }

    @Test func emptyInputIsReturnedUnchanged() async throws {
        #expect(try await run("") == "")
        #expect(try await run("clean already") == "clean already")
    }
}
