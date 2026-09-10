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
        hotkey: Hotkey = .rightCommand,
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

    // Decoding tolerates missing keys so adding a field in a later version
    // never makes an existing settings file unreadable.
    private enum CodingKeys: String, CodingKey {
        case engineID, hotkey, disabledProcessors, dictionary, appendTrailingSpace, launchAtLogin, playSounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineID = try c.decode(EngineID.self, forKey: .engineID)
        // An empty chord can never fire, so treat it like a missing key.
        let decodedHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        hotkey = decodedHotkey.flatMap { $0.keyCodes.isEmpty ? nil : $0 } ?? .rightCommand
        disabledProcessors = try c.decodeIfPresent(Set<String>.self, forKey: .disabledProcessors) ?? []
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
