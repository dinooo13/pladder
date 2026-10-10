import Foundation
import Observation

/// Calls `onChange` after every change to what `track` reads, from `start`
/// until `stop`.
///
/// `withObservationTracking` fires once per change, so the loop re-arms it
/// from its own callback. That callback runs before the new value is stored,
/// hence the hop onto a task to act on it. Each `start` begins a generation
/// of its own, and a callback armed by an older one ends there: one left
/// pending by a `stop` would otherwise re-arm after the next `start`, and two
/// chains would fire for every change from then on.
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
