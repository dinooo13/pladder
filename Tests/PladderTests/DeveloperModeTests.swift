#if PLADDER_DEV_MODES
import Foundation
import Testing
@testable import Pladder

struct DeveloperModeTests {
    @Test func screenshotsTakeTheDirectoryAfterTheFlag() {
        let arguments = ["Pladder", "--screenshots", "/tmp/shots", "--settings-scene"]
        #expect(Screenshots.directory(in: arguments) == URL(filePath: "/tmp/shots"))
    }

    @Test func screenshotsFlagLastWithNoDirectoryIsNoRequest() {
        #expect(Screenshots.directory(in: ["Pladder", "--managed", "--screenshots"]) == nil)
    }

    @Test func screenshotsWithoutTheFlagAreNoRequest() {
        #expect(Screenshots.directory(in: ["Pladder", "--settings-scene", "/tmp/shots"]) == nil)
    }

    @Test func overlayDemoIsRequestedOnlyByItsFlag() {
        #expect(OverlayDemo.isRequested(in: ["Pladder", "--style", "minimal", "--overlay-demo"]))
        #expect(!OverlayDemo.isRequested(in: ["Pladder", "--screenshots", "/tmp/shots"]))
    }
}
#endif
