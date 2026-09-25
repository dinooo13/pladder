import Testing
@testable import PladderCore

@Suite struct SpokenPunctuationTests {
    private func run(_ text: String, hint: (@Sendable (String) -> String?)? = nil) async throws -> String {
        try await SpokenPunctuation(languageHint: hint).process(text)
    }

    // MARK: What the speech model leaves behind

    @Test func absorbsTheSpeechModelsOwnPunctuation() async throws {
        // Parakeet's output for "…verschieben Fragezeichen" and "…to three
        // question mark": its mark and the spoken one become one.
        #expect(try await run("Können wir den Termin auf drei verschieben? Fragezeichen.")
            == "Können wir den Termin auf drei verschieben?")
        #expect(try await run("Can we push the call to three question mark?") == "Can we push the call to three?")
    }

    @Test func turnsEachLanguagesMarksIntoPunctuation() async throws {
        #expect(try await run("Hi Sarah comma thanks") == "Hi Sarah, thanks")
        #expect(try await run("Hallo Sarah Komma danke") == "Hallo Sarah, danke")
        #expect(try await run("Wow exclamation mark that worked") == "Wow! That worked")
        #expect(try await run("Das klappt Ausrufezeichen") == "Das klappt!")
        #expect(try await run("Es gibt drei Dinge Doppelpunkt Milch, Eier, Brot") == "Es gibt drei Dinge: Milch, Eier, Brot")
        #expect(try await run("first part semicolon second part") == "first part; second part")
        #expect(try await run("That is all full stop") == "That is all.")
        #expect(try await run("Podemos mover la llamada signo de interrogación") == "Podemos mover la llamada?")
        #expect(try await run("primero punto y coma segundo") == "primero; segundo")
    }

    @Test func capitalisesTheWordAfterASentenceMark() async throws {
        #expect(try await run("done question mark what next") == "done? What next")
        #expect(try await run("fertig Fragezeichen dann los") == "fertig? Dann los")
        #expect(try await run("send it question mark iPhone users too") == "send it? iPhone users too")
    }

    @Test func startsAParagraphAndKeepsTheSentenceMarkBeforeIt() async throws {
        #expect(try await run("That is the summary. New paragraph. next we ship.")
            == "That is the summary.\n\nNext we ship.")
        #expect(try await run("Das war es. Neuer Absatz jetzt weiter") == "Das war es.\n\nJetzt weiter")
    }

    @Test func aCommaBetweenDigitsIsTheDecimalComma() async throws {
        #expect(try await run("Es waren 3 Komma 5 Prozent") == "Es waren 3,5 Prozent")
        #expect(try await run("fueron 3 coma 5 grados", hint: { _ in "es" }) == "fueron 3,5 grados")
    }

    // MARK: What stays a word

    @Test func leavesAmbiguousWordsAlone() async throws {
        let texts = [
            "The trial period ends on Friday.",
            "Das ist ein wichtiger Punkt. Punkt acht Uhr geht es los.",
            "Ese es el punto clave.",
            "The colon is part of the large intestine.",
            "Tenemos dos puntos de vista.",
        ]
        for text in texts {
            #expect(try await run(text, hint: { _ in nil }) == text)
        }
    }

    @Test func spanishComaNeedsSpanishEvidence() async throws {
        #expect(try await run("The patient was in a coma for a week.", hint: { _ in "en" })
            == "The patient was in a coma for a week.")
        #expect(try await run("The patient was in a coma for a week.") == "The patient was in a coma for a week.")
        #expect(try await run("Hola Sara coma gracias", hint: { _ in "es" }) == "Hola Sara, gracias")
    }

    @Test func leavesTextWithoutSpokenMarksUnchanged() async throws {
        let text = "Der Build läuft auf der CI durch, und die Tests brauchen weniger als eine Sekunde."
        #expect(try await run(text) == text)
        #expect(try await run("") == "")
    }

    @Test func partsOfLongerWordsAreNotMarks() async throws {
        #expect(try await run("Kommandozeile und Kommata") == "Kommandozeile und Kommata")
        #expect(try await run("commas and commander") == "commas and commander")
    }
}
