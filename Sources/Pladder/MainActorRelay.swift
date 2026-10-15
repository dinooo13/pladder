@MainActor
final class MainActorRelay<Value: Sendable> {
    var handler: ((Value) -> Void)?

    nonisolated func send(_ value: Value) {
        Task { @MainActor in self.handler?(value) }
    }
}
