import Foundation

/// Everything the user can change. Persisted as JSON by `SettingsStore`.
public struct Settings: Codable, Sendable, Equatable {
    /// The ID the cleanup step used before it became a pluggable slot. Only
    /// read during migration; never written back.
    public static let legacyFoundationModelProcessorID = "foundation-model"
    public static let defaultCleanupProviderID = "apple-intelligence"

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
    /// Run the selected cleanup provider between dictionary and whitespace.
    public var cleanupEnabled: Bool
    /// Which `CleanupRegistry` entry the cleanup slot uses.
    public var cleanupProviderID: String

    public init(
        engineID: EngineID,
        hotkey: Hotkey = .rightOption,
        disabledProcessors: Set<String> = [],
        dictionary: [DictionaryEntry] = [],
        appendTrailingSpace: Bool = true,
        launchAtLogin: Bool = false,
        playSounds: Bool = true,
        cleanupEnabled: Bool = false,
        cleanupProviderID: String = Settings.defaultCleanupProviderID
    ) {
        self.engineID = engineID
        self.hotkey = hotkey
        self.disabledProcessors = disabledProcessors
        self.dictionary = dictionary
        self.appendTrailingSpace = appendTrailingSpace
        self.launchAtLogin = launchAtLogin
        self.playSounds = playSounds
        self.cleanupEnabled = cleanupEnabled
        self.cleanupProviderID = cleanupProviderID
    }

    // Decoding tolerates missing keys so adding a field in a later version
    // never makes an existing settings file unreadable.
    private enum CodingKeys: String, CodingKey {
        case engineID, hotkey, disabledProcessors, dictionary, appendTrailingSpace, launchAtLogin, playSounds
        case cleanupEnabled, cleanupProviderID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineID = try c.decode(EngineID.self, forKey: .engineID)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .rightOption
        // The cleanup step used to be a plain processor toggled through
        // `disabledProcessors`. Files written before the slot existed carry
        // its ID there; strip it and fold it into `cleanupEnabled` so the
        // user's choice survives. An explicit key always wins.
        var disabled = try c.decodeIfPresent(Set<String>.self, forKey: .disabledProcessors) ?? []
        let legacyOff = disabled.remove(Self.legacyFoundationModelProcessorID) != nil
        disabledProcessors = disabled
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? !legacyOff
        cleanupProviderID = try c.decodeIfPresent(String.self, forKey: .cleanupProviderID)
            ?? Self.defaultCleanupProviderID
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? []
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true
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

    /// Returns the saved settings, or the defaults when there is no file. A
    /// file that exists but cannot be decoded is moved aside rather than left
    /// in place to be overwritten by the next save, so a user's dictionary is
    /// never silently lost.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
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
