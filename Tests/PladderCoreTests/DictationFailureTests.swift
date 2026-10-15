import Foundation
import Testing
@testable import PladderCore

@Suite struct DictationFailureTests {
    @Test func engineNotLoadedIsRecognised() {
        #expect(DictationFailure(TranscriptionError.notLoaded) == .engineNotLoaded)
    }

    @Test func pasteKeystrokeIsRecognised() {
        #expect(DictationFailure(OutputError.eventCreationFailed) == .pasteKeystroke)
    }

    @Test func anythingElseKeepsItsOwnDescription() {
        let error = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "something else went wrong"])
        #expect(DictationFailure(error) == .other(detail: "something else went wrong"))
    }
}
