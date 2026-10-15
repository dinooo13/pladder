import Foundation

public struct EngineRegistry: Sendable {
    public struct Entry: Sendable, Identifiable {
        public var id: EngineID
        public var displayName: String
        public var detail: String
        public var make: @Sendable () -> any TranscriptionEngine

        public init(
            id: EngineID,
            displayName: String,
            detail: String,
            make: @escaping @Sendable () -> any TranscriptionEngine
        ) {
            self.id = id
            self.displayName = displayName
            self.detail = detail
            self.make = make
        }
    }

    public private(set) var available: [Entry]

    public init(_ entries: [Entry] = []) {
        available = entries
    }

    public mutating func register(_ entry: Entry) {
        available.removeAll { $0.id == entry.id }
        available.append(entry)
    }

    public func entry(for id: EngineID) -> Entry? {
        available.first { $0.id == id }
    }

    // Falls back to the first engine for an unknown ID, e.g. one removed in an update.
    public func make(_ id: EngineID) -> (any TranscriptionEngine)? {
        (entry(for: id) ?? available.first)?.make()
    }
}
