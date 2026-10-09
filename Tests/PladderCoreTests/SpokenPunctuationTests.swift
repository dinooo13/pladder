import Testing
@testable import PladderCore

@Suite struct SpokenPunctuationTests {
    private func run(_ text: String, hint: (@Sendable (String) -> String?)? = nil) async throws -> String {
        SpokenPunctuation(languageHint: hint).process(text)
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

    @Test func aMarkAfterAnArticleIsTheNoun() async throws {
        #expect(try await run("add a semicolon after the return") == "add a semicolon after the return")
        #expect(try await run("the Oxford comma debate") == "the Oxford comma debate")
        #expect(try await run("ein großes Fragezeichen dahinter") == "ein großes Fragezeichen dahinter")
        #expect(try await run("Let's start a new paragraph here") == "Let's start a new paragraph here")
        #expect(try await run("A semicolon joins two clauses") == "A semicolon joins two clauses")
        #expect(try await run("falta un punto y coma aquí") == "falta un punto y coma aquí")
    }

    @Test func aMarkAfterANounOrAPronounIsStillDictated() async throws {
        // "end" is no adjective, so "the end" is a whole noun phrase and the
        // comma after it is dictated.
        #expect(try await run("read it to the end comma and then stop") == "read it to the end, and then stop")
        // "that" and "das" end a question as often as they start a noun
        // phrase, so on their own they are no evidence.
        #expect(try await run("What is that question mark") == "What is that?")
        #expect(try await run("Was ist das Fragezeichen") == "Was ist das?")
        // A capital A in mid-sentence is the letter, not the article.
        #expect(try await run("take plan A comma not plan B") == "take plan A, not plan B")
        // The speech model's own mark ends the noun phrase.
        #expect(try await run("I read the book. Full stop.") == "I read the book.")
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
