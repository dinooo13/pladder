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

    /// How long the "press ⌘V" hint rests before it leaves. A hold, not
    /// motion, but it scales with the speed all the same: without
    /// Accessibility the hint follows every dictation, and someone who chose
    /// Instant wants the overlay out of the way, not a message to read.
    public var copiedHoldDuration: Duration {
        switch self {
        case .instant: .milliseconds(700)
        case .quick: .seconds(1)
        case .expressive: .seconds(1.5)
        }
    }
}

/// Which model the polish runs through. Pure data; PladderRefine maps each
/// case to a model and the app words it.
public enum PolishModel: String, Codable, Sendable, CaseIterable, Equatable {
    /// Apple's on-device model, part of macOS: nothing to download.
    case appleIntelligence
    /// S1-mini by Superwhisper at full precision (16-bit), downloaded once.
    case s1Mini
    /// The same model at 8-bit: about half the download and memory, and
    /// faster, for a little accuracy (docs/BENCHMARKS.md).
    case s1Mini8Bit
}

/// Everything the user can change. Persisted as JSON by `SettingsStore`.
public struct Settings: Codable, Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    /// Pressed at any point while `hotkey` is held, this makes the dictation
    /// end with Return, which sends a chat message or runs a command. V by
    /// default, within reach of the hand holding the default hotkey. Empty
    /// turns it off.
    public var submitKey: Hotkey
    /// Every dictation runs through the on-device model before it is pasted.
    /// Experimental and off by default: the model costs one to three seconds,
    /// so this sits on the normal hotkey's release path.
    public var polishDictations: Bool
    /// What `polishDictations` runs the text through.
    public var polishModel: PolishModel
    /// A chord that starts a recording on one press and ends it on the next.
    /// The same chord as `hotkey` makes that key hybrid: a tap latches, a hold
    /// stops at release. Empty, the default, turns it off.
    public var toggleHotkey: Hotkey
    /// Processor IDs that are turned off. Absent means enabled.
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    /// Insert a trailing space after each dictation so consecutive dictations
    /// don't run together.
    public var appendTrailingSpace: Bool
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

    /// The defaults, here and nowhere else: the decoder starts from them too.
    public init(engineID: EngineID) {
        self.engineID = engineID
        hotkey = .optionSpace
        submitKey = .keyV
        polishDictations = false
        polishModel = .appleIntelligence
        toggleHotkey = Hotkey(keyCodes: [])
        disabledProcessors = []
        dictionary = []
        appendTrailingSpace = true
        playSounds = true
        muteOutputWhileDictating = false
        appearance = .system
        overlayStyle = .compact
        overlayGlass = true
        overlayAnimationSpeed = .quick
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case engineID, hotkey, submitKey, polishDictations, polishModel, toggleHotkey
        case disabledProcessors, dictionary, appendTrailingSpace, playSounds
        case muteOutputWhileDictating, appearance, overlayStyle, overlayGlass, overlayAnimationSpeed
        // Read once for the migration, never written.
        case polishHotkey
    }

    /// Keys earlier versions wrote and this one no longer does. `SettingsStore`
    /// keeps keys it does not know, so a newer build's settings survive an
    /// older build saving; these it drops, since nothing will read them again.
    /// `launchAtLogin` mirrored the login item, which is its own source of
    /// truth and was never read back.
    static let retiredKeys = [CodingKeys.polishHotkey.rawValue, "launchAtLogin"]

    /// Starts from the defaults and takes every value the file has that this
    /// build can read, one key at a time. A value it cannot read — a case a
    /// newer version added, a hand edit, one damaged dictionary row — keeps
    /// its default instead of failing the whole file, because a failure moves
    /// the file aside and the user starts over with an empty dictionary. Only
    /// a file that is not a JSON object at all fails. What was dropped is
    /// reported through `SettingsDecodingReport`, so the store can keep a copy.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let report = decoder.userInfo[SettingsDecodingReport.key] as? SettingsDecodingReport
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard c.contains(key) else { return nil }
            do {
                return try c.decodeIfPresent(type, forKey: key)
            } catch {
                report?.dropped(key.rawValue)
                return nil
            }
        }

        // A missing or unreadable engine is repaired by the app, which knows
        // the registry; an empty ID is never registered.
        self.init(engineID: read(EngineID.self, .engineID) ?? EngineID(""))
        // An empty chord can never fire, so treat it like a missing key.
        if let hotkey = read(Hotkey.self, .hotkey), !hotkey.keyCodes.isEmpty { self.hotkey = hotkey }
        // Unlike the hotkey, an empty submit key is meaningful: it is how the
        // feature is switched off. The same holds for the toggle key.
        if let submitKey = read(Hotkey.self, .submitKey) { self.submitKey = submitKey }
        if let toggleHotkey = read(Hotkey.self, .toggleHotkey) { self.toggleHotkey = toggleHotkey }
        // Once a chord of its own, the polish is now a Processing toggle.
        // A stored chord migrates to `true`, so the feature the user asked
        // for turns on with the update; nothing is written under the old key.
        if let polish = read(Bool.self, .polishDictations) {
            polishDictations = polish
        } else if let legacy = read(Hotkey.self, .polishHotkey) {
            polishDictations = !legacy.isEmpty
        }
        if let polishModel = read(PolishModel.self, .polishModel) { self.polishModel = polishModel }
        if let disabled = read([String].self, .disabledProcessors) { disabledProcessors = Set(disabled) }
        if let rows = read([Lossy<DictionaryEntry>].self, .dictionary) {
            dictionary = rows.compactMap(\.value)
            if dictionary.count < rows.count { report?.dropped(CodingKeys.dictionary.rawValue) }
        }
        if let value = read(Bool.self, .appendTrailingSpace) { appendTrailingSpace = value }
        if let value = read(Bool.self, .playSounds) { playSounds = value }
        if let value = read(Bool.self, .muteOutputWhileDictating) { muteOutputWhileDictating = value }
        if let value = read(Appearance.self, .appearance) { appearance = value }
        if let value = read(OverlayStyle.self, .overlayStyle) { overlayStyle = value }
        if let value = read(Bool.self, .overlayGlass) { overlayGlass = value }
        if let value = read(OverlayAnimationSpeed.self, .overlayAnimationSpeed) { overlayAnimationSpeed = value }
    }

    // Encoding mirrors the synthesized one, minus the legacy `polishHotkey`
    // key that only the decoder above reads.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engineID, forKey: .engineID)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(submitKey, forKey: .submitKey)
        try c.encode(polishDictations, forKey: .polishDictations)
        try c.encode(polishModel, forKey: .polishModel)
        try c.encode(toggleHotkey, forKey: .toggleHotkey)
        try c.encode(disabledProcessors, forKey: .disabledProcessors)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(appendTrailingSpace, forKey: .appendTrailingSpace)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(muteOutputWhileDictating, forKey: .muteOutputWhileDictating)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(overlayStyle, forKey: .overlayStyle)
        try c.encode(overlayGlass, forKey: .overlayGlass)
        try c.encode(overlayAnimationSpeed, forKey: .overlayAnimationSpeed)
    }

    public func isProcessorEnabled(_ id: String) -> Bool {
        !disabledProcessors.contains(id)
    }

    public mutating func setProcessor(_ id: String, enabled: Bool) {
        if enabled { disabledProcessors.remove(id) } else { disabledProcessors.insert(id) }
    }
}

/// Collects the keys `Settings` had to drop while decoding. Passed in through
/// the decoder's `userInfo`; nil there, which is every decode but the store's,
/// means nobody is asking.
public final class SettingsDecodingReport: @unchecked Sendable {
    // `@unchecked`: written only by the decode that owns it, on one thread,
    // and read after that decode returns.
    static let key = CodingUserInfoKey(rawValue: "de.dinooo13.pladder.settingsDecodingReport")!

    public private(set) var droppedKeys: [String] = []

    public init() {}

    func dropped(_ key: String) { droppedKeys.append(key) }
}

/// One element of an array that decodes to nil instead of failing the array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
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

    /// Returns the saved settings, or the defaults when there is no file.
    ///
    /// Nothing the user wrote is ever lost to a load. A file that is not
    /// settings at all is moved aside rather than left to be overwritten by
    /// the next save; a file that decoded with something dropped is copied
    /// aside and kept. Each copy gets a name of its own, so an older one is
    /// never replaced.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        let decoder = JSONDecoder()
        let report = SettingsDecodingReport()
        decoder.userInfo[SettingsDecodingReport.key] = report
        do {
            let settings = try decoder.decode(Settings.self, from: data)
            if !report.droppedKeys.isEmpty {
                try? FileManager.default.copyItem(at: url, to: backupURL())
            }
            return settings
        } catch {
            try? FileManager.default.moveItem(at: url, to: backupURL())
            return defaults
        }
    }

    /// Writes `settings`, keeping every key in the existing file that this
    /// build does not know: a newer build's settings must survive an older
    /// one saving over them, which is what happens when two copies of the
    /// app, or two worktrees, share the file.
    public func save(_ settings: Settings) throws {
        let ours = try JSONEncoder().encode(settings)
        guard var object = try JSONSerialization.jsonObject(with: ours) as? [String: Any] else { return }
        if let existing = try? Data(contentsOf: url),
           let theirs = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            var kept = theirs.filter { !Settings.retiredKeys.contains($0.key) }
            kept.merge(object) { _, ours in ours }
            object = kept
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// `settings.broken-<time>.json` beside the file, unique to the second
    /// and then by a counter, so a second broken load never replaces the first
    /// backup.
    private func backupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + ".broken-" + formatter.string(from: Date())
        var candidate = directory.appending(path: base + ".json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)-\(counter).json")
            counter += 1
        }
        return candidate
    }
}
