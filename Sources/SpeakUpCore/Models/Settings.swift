import Foundation

/// Everything the user can change. Persisted as JSON by `SettingsStore`.
public struct Settings: Codable, Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    /// Processor IDs that are turned off. Absent means enabled.
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    /// Insert a trailing space after each dictation so consecutive dictations
    /// don't run together.
    public var appendTrailingSpace: Bool
    public var launchAtLogin: Bool
    /// Play a short sound on record start/stop.
    public var playSounds: Bool

    public init(
        engineID: EngineID,
        hotkey: Hotkey = .rightOption,
        disabledProcessors: Set<String> = [],
        dictionary: [DictionaryEntry] = [],
        appendTrailingSpace: Bool = true,
        launchAtLogin: Bool = false,
        playSounds: Bool = true
    ) {
        self.engineID = engineID
        self.hotkey = hotkey
        self.disabledProcessors = disabledProcessors
        self.dictionary = dictionary
        self.appendTrailingSpace = appendTrailingSpace
        self.launchAtLogin = launchAtLogin
        self.playSounds = playSounds
    }

    public func isProcessorEnabled(_ id: String) -> Bool {
        !disabledProcessors.contains(id)
    }

    public mutating func setProcessor(_ id: String, enabled: Bool) {
        if enabled { disabledProcessors.remove(id) } else { disabledProcessors.insert(id) }
    }
}

/// Loads and saves `Settings` as JSON. Pure Foundation, so it is testable with
/// a temp directory.
public final class SettingsStore: Sendable {
    public let url: URL
    private let defaults: Settings

    public init(url: URL, defaults: Settings) {
        self.url = url
        self.defaults = defaults
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            return defaults
        }
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
