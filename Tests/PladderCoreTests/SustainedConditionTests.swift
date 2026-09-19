import Foundation
import Testing
@testable import PladderCore

@Suite struct SustainedConditionTests {
    private let t0 = ContinuousClock.now

    @Test func firstObservationNeverSustains() {
        var c = SustainedCondition()
        // Nothing is known about how long it has been true, so the answer is no.
        #expect(c.observe(true, at: t0) == false)
        #expect(c.observe(false, at: t0) == false)
    }

    @Test func sustainsAfterThreshold() {
        var c = SustainedCondition()
        #expect(c.observe(true, at: t0) == false)
        #expect(c.observe(true, at: t0 + .seconds(2)) == false)
        #expect(c.observe(true, at: t0 + .seconds(4)) == true)
        // And stays sustained while it keeps being true.
        #expect(c.observe(true, at: t0 + .seconds(6)) == true)
    }

    @Test func resetsOnFalse() {
        var c = SustainedCondition()
        #expect(c.observe(true, at: t0) == false)
        #expect(c.observe(true, at: t0 + .seconds(4)) == true)
        // One negative observation drops it at once and restarts the clock.
        #expect(c.observe(false, at: t0 + .seconds(6)) == false)
        #expect(c.observe(true, at: t0 + .seconds(8)) == false)
        #expect(c.observe(true, at: t0 + .seconds(10)) == false)
        #expect(c.observe(true, at: t0 + .seconds(12)) == true)
    }

    @Test func thresholdIsConfigurable() {
        var c = SustainedCondition(threshold: .milliseconds(500))
        #expect(c.observe(true, at: t0) == false)
        #expect(c.observe(true, at: t0 + .milliseconds(400)) == false)
        #expect(c.observe(true, at: t0 + .milliseconds(500)) == true)
    }
}
