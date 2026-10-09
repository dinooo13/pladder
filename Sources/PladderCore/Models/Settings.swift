import Foundation

public enum Appearance: String, Codable, Sendable, CaseIterable, Equatable {
    case system, light, dark
}

public enum OverlayStyle: String, Codable, Sendable, CaseIterable, Equatable {
    case menuBar, minimal, compact, liveTranscript
}

public enum OverlayAnimationSpeed: String, Codable, Sendable, CaseIterable, Equatable {
    case instant, quick, expressive

    // Scales with the speed too: without Accessibility the hint follows every dictation.
    public var copiedHoldDuration: Duration {
        switch self {
        case .instant: .milliseconds(700)
        case .quick: .seconds(1)
        case .expressive: .seconds(1.5)
        }
    }
}

public enum PolishModel: String, Codable, Sendable, CaseIterable, Equatable {
    case appleIntelligence
    case s1Mini
    case s1Mini8Bit
}

public struct Settings: Codable, Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    public var submitKey: Hotkey
    public var polishDictations: Bool
    public var polishModel: PolishModel
    public var toggleHotkey: Hotkey
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    public var appendTrailingSpace: Bool
    public var playSounds: Bool
    public var muteOutputWhileDictating: Bool
    public var appearance: Appearance
    public var overlayStyle: OverlayStyle
    public var overlayGlass: Bool
    public var overlayAnimationSpeed: OverlayAnimationSpeed

    // The defaults, here and nowhere else: the decoder starts from them too.
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

    private enum CodingKeys: String, CodingKey {
        case engineID, hotkey, submitKey, polishDictations, polishModel, toggleHotkey
        case disabledProcessors, dictionary, appendTrailingSpace, playSounds
        case muteOutputWhileDictating, appearance, overlayStyle, overlayGlass, overlayAnimationSpeed
    }

    private enum LegacyKeys: String, CodingKey {
        case polishHotkey
    }

    // Dropped on save, unlike keys this build does not know, which may be a newer build's.
    static let retiredKeys = [LegacyKeys.polishHotkey.rawValue, "launchAtLogin"]

    // Key by key on top of the defaults: a value this build cannot read keeps its
    // default. See docs/ARCHITECTURE.md, "Settings file".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let report = decoder.userInfo[SettingsDecodingReport.key] as? SettingsDecodingReport
        func read<T: Decodable, Key>(_ type: T.Type, _ key: Key, in c: KeyedDecodingContainer<Key>) -> T? {
            guard c.contains(key) else { return nil }
            do {
                return try c.decodeIfPresent(type, forKey: key)
            } catch {
                report?.dropped(key.stringValue)
                return nil
            }
        }
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { read(type, key, in: c) }

        // The app repairs a missing engine; an empty ID is never registered.
        self.init(engineID: read(EngineID.self, .engineID) ?? EngineID(""))
        // An empty hotkey never fires, so it counts as missing; an empty submit or toggle
        // key means off.
        if let hotkey = read(Hotkey.self, .hotkey), !hotkey.keyCodes.isEmpty { self.hotkey = hotkey }
        if let submitKey = read(Hotkey.self, .submitKey) { self.submitKey = submitKey }
        if let toggleHotkey = read(Hotkey.self, .toggleHotkey) { self.toggleHotkey = toggleHotkey }
        // A polish chord stored by an older version turns the polish toggle on.
        if let polish = read(Bool.self, .polishDictations) {
            polishDictations = polish
        } else if let chord = read(Hotkey.self, .polishHotkey, in: legacy) {
            polishDictations = !chord.isEmpty
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

    public mutating func setProcessor(_ id: String, enabled: Bool) {
        if enabled { disabledProcessors.remove(id) } else { disabledProcessors.insert(id) }
    }
}

public final class SettingsDecodingReport: @unchecked Sendable {
    // `@unchecked`: written only by the decode that owns it, on one thread,
    // and read after that decode returns.
    static let key = CodingUserInfoKey(rawValue: "de.dinooo13.pladder.settingsDecodingReport")!

    public private(set) var droppedKeys: [String] = []

    public init() {}

    func dropped(_ key: String) { droppedKeys.append(key) }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

public final class SettingsStore: Sendable {
    public let url: URL
    private let defaults: Settings

    public init(url: URL, defaults: Settings) {
        self.url = url
        self.defaults = defaults
    }

    // Nothing the user wrote is lost to a load: an unreadable file is moved aside, a
    // file decoded with something dropped is copied aside.
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

    // Keeps every key this build does not know: two worktrees' builds share the file,
    // and a newer build's settings must survive an older one saving.
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
