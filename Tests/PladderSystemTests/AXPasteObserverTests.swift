import Foundation
import Testing
@testable import PladderSystem

// Never reads the live focused element: the developer dictates while these run, and
// a harness launched from a trusted terminal is trusted too. The grant is stubbed.
@Suite(.timeLimit(.minutes(1))) struct AXPasteObserverTests {
    @Test func returnsNilPromptlyWithoutAccessibility() async {
        let observer = AXPasteObserver(isTrusted: { false })
        let started = ContinuousClock.now
        let observation = await observer.observe(pasted: "I tried Claud today")
        #expect(observation == nil)
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }

    @Test func manualAccessibilityOnlyWhereTheTreeIsMissing() {
        #expect(AXPasteObserver.wantsManualAccessibility(hasFocus: false, focusedRole: nil))
        #expect(AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: "AXWebArea"))
        #expect(!AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: "AXList"))
        #expect(!AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: "AXOutline"))
        #expect(!AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: "AXButton"))
        #expect(!AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: nil))
        #expect(!AXPasteObserver.wantsManualAccessibility(hasFocus: true, focusedRole: "AXTextField"))
    }

    @Test func theWindowIsThePastePlusAMargin() {
        let window = PasteWindow(start: 1_000, length: 20, characterCount: 5_000)
        #expect(window.windowStart == 1_000 - 64)
        #expect(window.windowEnd == 1_020 + 64)
        let long = PasteWindow(start: 1_000, length: 800, characterCount: 5_000)
        #expect(long.windowStart == 800)
        #expect(long.windowEnd == 2_000)
    }

    @Test func theWindowIsClampedToTheField() {
        let window = PasteWindow(start: 3, length: 10, characterCount: 13)
        #expect(window.anchorRange.location == 0)
        #expect(window.anchorRange.length == 13)
    }

    @Test func theWindowFollowsTheFieldsLength() {
        let window = PasteWindow(start: 100, length: 20, characterCount: 184)
        #expect(window.readRange(characterCount: 185).length == window.anchorRange.length + 1)
        #expect(window.readRange(characterCount: 182).length == window.anchorRange.length - 2)
        #expect(window.readRange(characterCount: 0).length == 0)
        let size = window.anchorRange.length
        #expect(window.readRange(characterCount: 1_000_000).length == 2 * size + 1_024)
    }

    @Test func theAnchorWindowSplitsIntoMarginPasteMargin() throws {
        let text = "Dear Bob, I tried Claud today Best"
        let start = ("Dear Bob, " as NSString).length
        let window = PasteWindow(
            start: start, length: ("I tried Claud today " as NSString).length,
            characterCount: (text as NSString).length)
        let split = try #require(window.split(text))
        #expect(split.before == "Dear Bob, ")
        #expect(split.pasted == "I tried Claud today ")
        #expect(split.after == "Best")
        #expect(window.split("too short") == nil)
    }
}
