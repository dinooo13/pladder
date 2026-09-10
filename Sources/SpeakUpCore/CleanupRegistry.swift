import Foundation

/// Maps cleanup provider IDs to factories, the same way `EngineRegistry` does
/// for transcription engines. The app registers every backend it can build at
/// launch and the settings picker lists `available`.
///
/// The cleanup slot is the one processor the user chooses between, so it needs
/// an availability probe on top of the plain factory: a backend can be present
/// in the build and still be unusable on this Mac (Apple Intelligence turned
/// off, model still downloading).
public struct CleanupRegistry: Sendable {
    public struct Entry: Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public var detail: String
        /// nil when usable, otherwise a short reason shown under the picker.
        public var availability: @Sendable () -> String?
        public var make: @Sendable () -> any TextProcessor

        public init(
            id: String,
            displayName: String,
            detail: String,
            availability: @escaping @Sendable () -> String?,
            make: @escaping @Sendable () -> any TextProcessor
        ) {
            self.id = id
            self.displayName = displayName
            self.detail = detail
            self.availability = availability
            self.make = make
        }
    }

    public private(set) var available: [Entry]

    public init(_ entries: [Entry] = []) {
        available = entries
    }

    /// Replaces the entry with the same ID in place, so the picker order does
    /// not shuffle when a provider is re-registered.
    public mutating func register(_ entry: Entry) {
        if let index = available.firstIndex(where: { $0.id == entry.id }) {
            available[index] = entry
        } else {
            available.append(entry)
        }
    }

    public func entry(for id: String) -> Entry? {
        available.first { $0.id == id }
    }

    /// The processor for the current settings, or nil when cleanup is off, the
    /// provider ID is unknown, or the provider is unavailable.
    ///
    /// Availability is checked here, at pipeline build time, rather than during
    /// the run: an unusable provider is simply left out of the pipeline instead
    /// of failing a dictation.
    public func makeProcessor(for settings: Settings) -> (any TextProcessor)? {
        guard settings.cleanupEnabled,
              let entry = entry(for: settings.cleanupProviderID),
              entry.availability() == nil
        else { return nil }
        return entry.make()
    }
}
