import Foundation

/// Which interface style the app uses. `NSApp.appearance` maps this: `nil`
/// for system, `.aqua` for light, `.darkAqua` for dark.
public enum Appearance: String, Codable, Sendable, CaseIterable, Equatable {
    case system, light, dark
}

/// Which overlay the pill shows while dictating. `liveTranscript` is the only
/// one that costs anything: it runs a pass over the audio so far four times a
/// second, in place of the warm pass the other styles run every two seconds.
public enum OverlayStyle: String, Codable, Sendable, CaseIterable, Equatable {
    case menuBar, minimal, compact, liveTranscript
}

/// How fast the pill flies in from the bottom edge and dives back down. Pure
/// data; the durations it maps to live with the overlay, so PladderCore stays
/// free of AppKit and SwiftUI.
public enum OverlayAnimationSpeed: String, Codable, Sendable, CaseIterable, Equatable {
    case instant, quick, expressive
}

/// Everything the user can change. Persisted as JSON by `SettingsStore`.
public struct Settings: Codable, Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    /// Pressed at any point while `hotkey` is held, this makes the dictation
    /// end with Return, which sends a chat message or runs a command. Empty
    /// turns it off.
    public var submitKey: Hotkey
    /// Processor IDs that are turned off. Absent means enabled.
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    /// Insert a trailing space after each dictation so consecutive dictations
    /// don't run together.
    public var appendTrailingSpace: Bool
    public var launchAtLogin: Bool
    /// Play a short sound on record start/stop.
    public var playSounds: Bool
    /// Mute the default output device while the key is held, so music or a
    /// call does not end up in the microphone. Off by default: some people
    /// want the audio to keep playing.
    public var muteOutputWhileDictating: Bool
    public var appearance: Appearance
    public var overlayStyle: OverlayStyle
    /// Liquid Glass behind the overlay pill; off gives a flat
    /// window-background fill.
    public var overlayGlass: Bool
    /// Speed of the fly-in/fly-out presentation animation.
    public var overlayAnimationSpeed: OverlayAnimationSpeed

    public init(
        engineID: EngineID,
        hotkey: Hotkey = .optionSpace,
        submitKey: Hotkey = .rightOption,
        disabledProcessors: Set<String> = [],
        dictionary: [DictionaryEntry] = [],
        appendTrailingSpace: Bool = true,
        launchAtLogin: Bool = false,
        playSounds: Bool = true,
        muteOutputWhileDictating: Bool = false,
        appearance: Appearance = .system,
        overlayStyle: OverlayStyle = .compact,
        overlayGlass: Bool = true,
        overlayAnimationSpeed: OverlayAnimationSpeed = .quick
    ) {
        self.engineID = engineID
        self.hotkey = hotkey
        self.submitKey = submitKey
        self.disabledProcessors = disabledProcessors
        self.dictionary = dictionary
        self.appendTrailingSpace = appendTrailingSpace
        self.launchAtLogin = launchAtLogin
        self.playSounds = playSounds
        self.muteOutputWhileDictating = muteOutputWhileDictating
        self.appearance = appearance
        self.overlayStyle = overlayStyle
        self.overlayGlass = overlayGlass
        self.overlayAnimationSpeed = overlayAnimationSpeed
    }

    // Decoding tolerates missing keys so adding a field in a later version
    // never makes an existing settings file unreadable.
    private enum CodingKeys: String, CodingKey {
        case engineID, hotkey, submitKey, disabledProcessors, dictionary, appendTrailingSpace, launchAtLogin, playSounds, appearance
        case overlayStyle, overlayGlass, overlayAnimationSpeed, muteOutputWhileDictating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineID = try c.decode(EngineID.self, forKey: .engineID)
        // An empty chord can never fire, so treat it like a missing key.
        let decodedHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        hotkey = decodedHotkey.flatMap { $0.keyCodes.isEmpty ? nil : $0 } ?? .optionSpace
        // Unlike the hotkey, an empty submit key is meaningful: it is how the
        // feature is switched off.
        submitKey = try c.decodeIfPresent(Hotkey.self, forKey: .submitKey) ?? .rightOption
        disabledProcessors = try c.decodeIfPresent(Set<String>.self, forKey: .disabledProcessors) ?? []
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? []
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        overlayStyle = try c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle) ?? .compact
        overlayGlass = try c.decodeIfPresent(Bool.self, forKey: .overlayGlass) ?? true
        overlayAnimationSpeed = try c.decodeIfPresent(OverlayAnimationSpeed.self, forKey: .overlayAnimationSpeed) ?? .quick
        muteOutputWhileDictating = try c.decodeIfPresent(Bool.self, forKey: .muteOutputWhileDictating) ?? false
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
