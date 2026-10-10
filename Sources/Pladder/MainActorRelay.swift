/// Carries values from a nonisolated callback onto the main actor, and lets
/// the callback be handed to something built before its handler exists: the
/// coordinator's events, the learner's proposals and the model files' status
/// all start out that way in `AppModel.init`.
@MainActor
final class MainActorRelay<Value: Sendable> {
    var handler: ((Value) -> Void)?

    nonisolated func send(_ value: Value) {
        Task { @MainActor in self.handler?(value) }
    }
}
