import Foundation
import Observation

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
