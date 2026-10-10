import Foundation

@MainActor
public final class EngineLoader {
    public private(set) var engine: any TranscriptionEngine
    public private(set) var status: EngineStatus = .unloaded
    public var onStatusChange: (EngineStatus) -> Void = { _ in }

    private let registry: EngineRegistry
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    public init(registry: EngineRegistry, engineID: EngineID, pollInterval: Duration = .milliseconds(250)) {
        guard let engine = registry.make(engineID) else {
            preconditionFailure("EngineRegistry has no engines")
        }
        self.registry = registry
        self.pollInterval = pollInterval
        self.engine = engine
    }

    public func load() {
        pollTask?.cancel()
        loadTask?.cancel()
        let engine = self.engine
        // The poll is the only writer of `status` while loading, so the failure text
        // always comes from the engine itself.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollStatus(of: engine)
        }
        // An engine's load cannot be cancelled, only outlived: the identity check keeps an
        // engine no longer current from writing its status or stopping its successor's poll.
        loadTask = Task { [weak self] in
            guard let self else { return }
            let status: EngineStatus
            do {
                try await engine.load()
                status = await engine.status
            } catch {
                let reported = await engine.status
                if case .failed = reported {
                    status = reported
                } else {
                    status = .failed(.loadFailed(detail: error.localizedDescription))
                }
            }
            guard !Task.isCancelled, engine === self.engine else { return }
            self.setStatus(status)
            self.pollTask?.cancel()
        }
    }

    // Returns the replaced engine, for the caller to unload once nothing uses it.
    @discardableResult
    public func select(_ id: EngineID) -> (any TranscriptionEngine)? {
        guard let next = registry.make(id) else { return nil }
        let previous = engine
        engine = next
        status = .unloaded
        onStatusChange(status)
        load()
        return previous
    }

    public func stop() {
        pollTask?.cancel()
        loadTask?.cancel()
    }

    private func pollStatus(of engine: any TranscriptionEngine) async {
        while !Task.isCancelled {
            let status = await engine.status
            guard !Task.isCancelled else { return }
            setStatus(status)
            switch status {
            case .ready, .failed: return
            default: break
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func setStatus(_ new: EngineStatus) {
        guard new != status else { return }
        status = new
        onStatusChange(new)
    }
}
