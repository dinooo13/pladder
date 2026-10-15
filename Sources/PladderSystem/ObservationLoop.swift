import Foundation
import Observation
import Synchronization

// `withObservationTracking` fires once, before the new value is stored, so the loop re-arms from a
// task. A callback from an older generation ends there: one pending at `stop()` would otherwise
// re-arm after the next `start()`, and two chains would fire for every change.
@MainActor
public final class ObservationLoop {
    private var generation = 0

    public init() {}

    public func start(
        tracking track: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        generation += 1
        arm(generation, track, onChange)
    }

    public func stop() {
        generation += 1
    }

    private func arm(
        _ generation: Int, _ track: @escaping @MainActor () -> Void, _ onChange: @escaping @MainActor () -> Void
    ) {
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                onChange()
                self.arm(generation, track, onChange)
            }
        }
    }
}

extension ObservationLoop {
    // Looks again on each change to what `condition` reads, not on a timer; a cancel ends the wait.
    public static func wait(until condition: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            let resume = ResumeOnce()
            let holds = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    resume.set(continuation)
                    let holds = withObservationTracking(condition) { resume(false) }
                    if holds { resume(true) }
                }
            } onCancel: {
                resume(true)
            }
            // A change resumes this from `willSet`, before the value is stored; it is stored by
            // the time this runs on the main actor.
            if holds { return }
        }
    }
}

// The tracking callback, the condition and a cancel may all resume it; the first one does. A
// cancel can come before the continuation exists, and is then kept for it.
private final class ResumeOnce: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Bool, Never>?, early: Bool?)>((nil, nil))

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let early: Bool? = state.withLock { state in
            if let early = state.early { return early }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func callAsFunction(_ value: Bool) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            if state.continuation == nil, state.early == nil { state.early = value }
            return state.continuation
        }
        continuation?.resume(returning: value)
    }
}
