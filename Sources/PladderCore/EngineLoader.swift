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
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// `pollInterval` is how often a loading engine's status is read; the
    /// tests shorten it.
    public init(registry: EngineRegistry, engineID: EngineID, pollInterval: Duration = .milliseconds(250)) {
        guard let engine = registry.make(engineID) else {
            preconditionFailure("EngineRegistry has no engines")
        }
        self.registry = registry
        self.pollInterval = pollInterval
        self.engine = engine
    }

    /// Loads the current engine, or re-runs a failed load.
    public func load() {
        pollTask?.cancel()
        loadTask?.cancel()
        let engine = self.engine
        // The poll is the single writer of `status` while loading, so the
        // failure text always comes from the engine itself.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollStatus(of: engine)
        }
        // An engine's load cannot be cancelled, only outlived: a `select` or
        // a second `load` while this one is in flight cancels the task, and
        // the identity check keeps an engine that is no longer current from
        // writing its status or stopping its successor's poll.
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
        loadTask?.cancel()
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
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func setStatus(_ new: EngineStatus) {
        guard new != status else { return }
        status = new
        onStatusChange(new)
    }
}
