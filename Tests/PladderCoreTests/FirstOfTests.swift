import Foundation
import Testing
@testable import PladderCore

@Suite(.timeLimit(.minutes(1))) struct FirstOfTests {
    @Test func theWorkWinsBeforeTheDeadline() async {
        let result = await firstOf(until: .now + .seconds(30)) { 42 }
        #expect(result.value == 42)
    }

    // Ignores cancellation, as a model call in flight does.
    @Test func theDeadlineWinsOverWorkThatIgnoresCancellation() async {
        let started = ContinuousClock.now
        let result = await firstOf(until: .now + .milliseconds(50)) { () -> Int in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { done.resume() }
            }
            return 42
        }
        #expect(result.value == nil)
        #expect(result.task.isCancelled)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
