import Foundation
import Testing
@testable import PladderRefine

// Nothing here calls the model: these run on a Mac without Apple
// Intelligence and keep `swift test` well under a second.

@Suite struct CorrectionReviewPromptTests {
    @Test func parsesYesAndNoCaseInsensitively() {
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "Yes") == true)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "  YES, it is the same name.") == true)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "\"no\"") == false)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "No.") == false)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "**No**") == false)
    }

    @Test func rejectsAnythingElse() {
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "") == nil)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "Nobody knows") == nil)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "Yesterday") == nil)
        #expect(FoundationModelsCorrectionReviewer.verdict(fromReply: "Maybe") == nil)
    }

    @Test func thePromptNamesAllThree() {
        #expect(FoundationModelsCorrectionReviewer.prompt(heard: "Claud", corrected: "Claude", sentence: "I tried Claud")
            == "HEARD: Claud\nCORRECTED: Claude\nSENTENCE: I tried Claud")
    }
}
