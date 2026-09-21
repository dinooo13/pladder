import Foundation

/// Owns the current engine and its load lifecycle: builds it from the
/// registry, loads it, polls its status while loading, and swaps it on
/// request. Foundation only; the coordinator subscribes for status.
@MainActor
public final class EngineLoader {
    public private(set) var engine: any TranscriptionEngine
    public private(set) var status: EngineStatus = .unloaded
    /// Called on the main actor each time `status` changes.
    public var onStatusChange: (EngineStatus) -> Void = { _ in }

    private let registry: EngineRegistry
    private var pollTask: Task<Void, Never>?

    public init(registry: EngineRegistry, engineID: EngineID) {
        guard let engine = registry.make(engineID) else {
            preconditionFailure("EngineRegistry has no engines")
        }
        self.registry = registry
        self.engine = engine
    }

    /// Loads the current engine, or re-runs a failed load.
    public func load() {
        pollTask?.cancel()
        let engine = self.engine
        // The poll is the single writer of `status` while loading, so the
        // failure text always comes from the engine itself.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollStatus(of: engine)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.load()
            } catch {
                let status = await engine.status
                if case .failed = status {
                    self.setStatus(status)
                } else {
                    self.setStatus(.failed(.loadFailed(detail: error.localizedDescription)))
                }
                self.pollTask?.cancel()
                return
            }
            self.setStatus(await engine.status)
            self.pollTask?.cancel()
        }
    }

    /// Switches to `id` and starts loading it. Returns the engine being
    /// replaced so the caller can unload it once nothing is using it, or
    /// nil when the registry cannot build `id`.
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
    }

    /// Cheap polling of the engine's status while it loads, so the UI can show
    /// download progress without every engine needing to expose a stream.
    private func pollStatus(of engine: any TranscriptionEngine) async {
        while !Task.isCancelled {
            let status = await engine.status
            guard !Task.isCancelled else { return }
            setStatus(status)
            switch status {
            case .ready, .failed: return
            default: break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func setStatus(_ new: EngineStatus) {
        guard new != status else { return }
        status = new
        onStatusChange(new)
    }
}
