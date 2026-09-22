import Foundation
import Testing
@testable import PladderCore

@Suite struct PhoneticGateTests {
    @Test func soundexMatchPasses() {
        #expect(PhoneticGate.soundex(PhoneticGate.key("Robert")) == "R163")
        #expect(PhoneticGate.soundex(PhoneticGate.key("Ashcraft")) == "A261")
        #expect(PhoneticGate.isClose("Claud", "Claude"))
        // Distance three, but the codes agree.
        #expect(PhoneticGate.isClose("Robert", "Rupert"))
    }

    @Test func editDistanceOfTwoPasses() {
        #expect(PhoneticGate.isClose("kubernetties", "Kubernetes"))
    }

    @Test func semanticRewriteFails() {
        #expect(!PhoneticGate.isClose("Friday", "Monday"))
    }

    @Test func nonASCIIUsesEditDistance() {
        #expect(PhoneticGate.soundex(PhoneticGate.key("Müller")) == nil)
        #expect(PhoneticGate.isClose("Muller", "Müller"))
        #expect(PhoneticGate.isClose("Strasse", "Straße"))
    }

    @Test func phrasesAreComparedWithoutSpaces() {
        #expect(PhoneticGate.isClose("get hub", "GitHub"))
        #expect(PhoneticGate.isClose("clodecode", "Claude Code"))
    }

    @Test func shortWordsNeedAnEditDistanceOfOne() {
        #expect(!PhoneticGate.isClose("the", "tea"))
        #expect(PhoneticGate.isClose("cat", "cot"))
    }

    @Test func unrelatedWordsFail() {
        #expect(!PhoneticGate.isClose("cat", "dog"))
        #expect(!PhoneticGate.isClose("meeting", "banana"))
        #expect(!PhoneticGate.isClose("", "Claude"))
    }
}
