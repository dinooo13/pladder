import Foundation
import Testing
@testable import PladderCore

@Suite struct DismissedCorrectionsTests {
    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pladder-tests-\(UUID().uuidString)/dismissed-corrections.json")
    }

    private let pair = CorrectionPair(heard: "Claud", corrected: "Claude")

    @Test func roundTripsThroughTheFile() async {
        let url = Self.temporaryURL()
        await DismissedCorrections(url: url).dismiss(pair)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await DismissedCorrections(url: url).contains(pair))
        #expect(await !DismissedCorrections(url: url).contains(CorrectionPair(heard: "get hub", corrected: "GitHub")))
    }

    @Test func matchingIsCaseInsensitive() async {
        let dismissed = DismissedCorrections(url: Self.temporaryURL())
        await dismissed.dismiss(pair)
        #expect(await dismissed.contains(CorrectionPair(heard: "CLAUD", corrected: "claude")))
    }

    @Test func aMissingFileIsEmpty() async {
        #expect(await !DismissedCorrections(url: Self.temporaryURL()).contains(pair))
    }

    @Test func anUnreadableFileIsEmptyAndLeftInPlace() async throws {
        let url = Self.temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(await !DismissedCorrections(url: url).contains(pair))
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}
