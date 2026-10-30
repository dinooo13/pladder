import Testing
@testable import PladderCore

@Suite struct ShortSentenceTests {
    private let both = ShortSentence(dropPeriod: true, dropCapital: true)

    @Test func dropsTheCapitalAndTheStopOfOneShortSentence() {
        #expect(both.apply("Yes.") == "yes")
        #expect(both.apply("Run this command in terminal: bash foo.") == "run this command in terminal: bash foo")
        #expect(both.apply("Open main.swift.") == "open main.swift")
        #expect(both.apply("Bring apples, pears, etc.") == "bring apples, pears, etc")
        #expect(both.apply("Über den Fluss.") == "über den Fluss")
    }

    @Test func eachHalfWorksAlone() {
        #expect(ShortSentence(dropPeriod: true, dropCapital: false).apply("Bash foo.") == "Bash foo")
        #expect(ShortSentence(dropPeriod: false, dropCapital: true).apply("Bash foo.") == "bash foo.")
        #expect(ShortSentence(dropPeriod: false, dropCapital: false).apply("Bash foo.") == "Bash foo.")
    }

    @Test func aQuestionLosesOnlyItsCapital() {
        #expect(both.apply("Is it done?") == "is it done?")
    }

    @Test func iAndWordsWithAnInnerCapitalKeepTheirs() {
        #expect(both.apply("I think so.") == "I think so")
        #expect(both.apply("I'm done.") == "I'm done")
        #expect(both.apply("I’ll check.") == "I’ll check")
        #expect(both.apply("API is down.") == "API is down")
        #expect(both.apply("ChatGPT said no.") == "ChatGPT said no")
        #expect(both.apply("LS-law") == "LS-law")
    }

    @Test func theStopOfAnEllipsisOrAnAbbreviationStays() {
        #expect(both.apply("Well...") == "well...")
        #expect(both.apply("Nimm z.B.") == "nimm z.B.")
        #expect(both.apply("We met in the U.S.") == "we met in the U.S.")
        #expect(both.apply(".") == ".")
    }

    @Test func moreThanOneSentenceOrTenWordsIsLeftAlone() {
        #expect(both.apply("Yes. Do it.") == "Yes. Do it.")
        #expect(both.apply("Really? Then go ahead.") == "Really? Then go ahead.")
        #expect(both.apply("One two three four five six seven eight nine ten eleven.")
            == "One two three four five six seven eight nine ten eleven.")
        #expect(both.apply("One two three four five six seven eight nine ten.")
            == "one two three four five six seven eight nine ten")
    }
}
