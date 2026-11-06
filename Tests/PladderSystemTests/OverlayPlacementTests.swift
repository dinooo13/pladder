import Foundation
import Testing
@testable import PladderSystem

@Suite struct OverlayPlacementTests {
    private let placement = OverlayPlacement(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visible: CGRect(x: 0, y: 70, width: 1512, height: 879),
        panel: CGSize(width: 320, height: 96),
        pillHeight: 56)

    @Test func restsAboveTheDock() {
        #expect(placement.frame(avoiding: nil).minY == 82)
    }

    @Test func restsAtTheEdgeClearanceWithoutADock() {
        var bare = placement
        bare.visible = CGRect(x: 0, y: 4, width: 1512, height: 945)
        #expect(bare.frame(avoiding: nil).minY == 64)
    }

    @Test func stepsOverAPromptBoxItWouldCover() {
        let prompt = CGRect(x: 456, y: 90, width: 600, height: 80)
        let frame = placement.frame(avoiding: prompt)
        #expect(frame.minY + 20 == prompt.maxY + 10)
    }

    @Test func staysPutForAFieldElsewhere() {
        let field = CGRect(x: 100, y: 600, width: 400, height: 30)
        #expect(placement.frame(avoiding: field) == placement.frame(avoiding: nil))
    }

    @Test func staysPutForAWholeTerminal() {
        let terminal = CGRect(x: 200, y: 80, width: 1100, height: 800)
        #expect(placement.frame(avoiding: terminal) == placement.frame(avoiding: nil))
    }

    @Test func staysPutForAFieldOnAnotherScreen() {
        let field = CGRect(x: 2000, y: 90, width: 600, height: 80)
        #expect(placement.frame(avoiding: field) == placement.frame(avoiding: nil))
    }

    @Test func staysPutWhenSteppingOverWouldLeaveTheScreen() {
        let tall = CGRect(x: 456, y: 90, width: 600, height: 380)
        var short = placement
        short.visible = CGRect(x: 0, y: 70, width: 1512, height: 420)
        #expect(short.frame(avoiding: tall) == short.frame(avoiding: nil))
    }
}
