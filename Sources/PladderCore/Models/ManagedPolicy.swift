import Foundation

// What an organisation's configuration profile fixes. Never written to the settings file:
// the app applies it on top of the user's own settings. See docs/ARCHITECTURE.md,
// "Managed policy".
public struct ManagedPolicy: Sendable, Equatable {
    public enum Key: String, CaseIterable, Sendable {
        case allowedEngines = "AllowedEngines"
        case polishDictations = "PolishDictations"
        case allowedPolishModels = "AllowedPolishModels"
        case learnCorrections = "LearnCorrections"
        case clipboardMode = "ClipboardMode"
        case updateChecks = "UpdateChecks"
    }

    // For the log: an admin's typo must be findable, and it never stops the app.
    public enum Problem: Sendable, Equatable {
        case wrongType(Key)
        case unknownValues(Key, [String])
        case noKnownValue(Key)
    }

    // A list: what the picker may offer, one entry pins it. nil leaves the choice to the user.
    public var allowedEngines: [EngineID]?
    public var allowedPolishModels: [PolishModel]?
    // A toggle: forced on or off. nil leaves it to the user.
    public var polishDictations: Bool?
    public var learnCorrections: Bool?
    public var updateChecks: Bool?
    // Only `true` means anything: a profile cannot grant Accessibility through Pladder.
    public var clipboardMode: Bool

    public static let none = ManagedPolicy()

    public init(
        allowedEngines: [EngineID]? = nil, allowedPolishModels: [PolishModel]? = nil,
        polishDictations: Bool? = nil, learnCorrections: Bool? = nil, updateChecks: Bool? = nil,
        clipboardMode: Bool = false
    ) {
        self.allowedEngines = allowedEngines
        self.allowedPolishModels = allowedPolishModels
        self.polishDictations = polishDictations
        self.learnCorrections = learnCorrections
        self.updateChecks = updateChecks
        self.clipboardMode = clipboardMode
    }

    // `value` hands over only what a profile forces, as the property list decoded it.
    public static func read(
        _ value: (Key) -> Any?, knownEngines: [EngineID]
    ) -> (policy: ManagedPolicy, problems: [Problem]) {
        var problems: [Problem] = []
        func bool(_ key: Key) -> Bool? {
            guard let raw = value(key) else { return nil }
            // A property list `<integer>` bridges to Bool too; only `<true/>` and `<false/>` count.
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                problems.append(.wrongType(key))
                return nil
            }
            return number.boolValue
        }
        func list<T>(_ key: Key, _ make: (String) -> T?) -> [T]? {
            guard let raw = value(key) else { return nil }
            guard let strings = raw as? [String] else {
                problems.append(.wrongType(key))
                return nil
            }
            var seen: Set<String> = []
            var known: [T] = []
            var unknown: [String] = []
            for string in strings where seen.insert(string).inserted {
                if let item = make(string) { known.append(item) } else { unknown.append(string) }
            }
            if !unknown.isEmpty { problems.append(.unknownValues(key, unknown)) }
            // A list of typos, or an empty one, would leave the picker with nothing to run.
            guard !known.isEmpty else {
                problems.append(.noKnownValue(key))
                return nil
            }
            return known
        }

        let policy = ManagedPolicy(
            allowedEngines: list(.allowedEngines) { id in
                knownEngines.first { $0.rawValue == id }
            },
            allowedPolishModels: list(.allowedPolishModels, PolishModel.init(rawValue:)),
            polishDictations: bool(.polishDictations),
            learnCorrections: bool(.learnCorrections),
            updateChecks: bool(.updateChecks),
            clipboardMode: bool(.clipboardMode) ?? false
        )
        return (policy, problems)
    }

    public var isEmpty: Bool { self == .none }

    public func apply(to settings: Settings) -> Settings {
        var settings = settings
        if let engines = allowedEngines, !engines.contains(settings.engineID) {
            settings.engineID = engines[0]
        }
        if let models = allowedPolishModels, !models.contains(settings.polishModel) {
            settings.polishModel = models[0]
        }
        if let polishDictations { settings.polishDictations = polishDictations }
        if let learnCorrections { settings.learnCorrections = learnCorrections }
        if let updateChecks { settings.checksForUpdatesAutomatically = updateChecks }
        return settings
    }

    // The views edit the settings in effect; this turns an edit back into the user's own, so
    // a managed value never reaches the settings file and removing the profile gives every
    // choice back. A value the edit left as the policy had it keeps what the user stored.
    public func userSettings(from edited: Settings, stored: Settings) -> Settings {
        let effective = apply(to: stored)
        var user = edited
        if edited.engineID == effective.engineID { user.engineID = stored.engineID }
        if edited.polishModel == effective.polishModel { user.polishModel = stored.polishModel }
        if edited.polishDictations == effective.polishDictations { user.polishDictations = stored.polishDictations }
        if edited.learnCorrections == effective.learnCorrections { user.learnCorrections = stored.learnCorrections }
        if edited.checksForUpdatesAutomatically == effective.checksForUpdatesAutomatically {
            user.checksForUpdatesAutomatically = stored.checksForUpdatesAutomatically
        }
        return user
    }

    // In the order the app offers them.
    public func engines(from available: [EngineID]) -> [EngineID] {
        guard let allowedEngines else { return available }
        return available.filter(allowedEngines.contains)
    }

    public var polishModels: [PolishModel] {
        guard let allowedPolishModels else { return PolishModel.allCases }
        return PolishModel.allCases.filter(allowedPolishModels.contains)
    }

    public var pinsEngine: Bool { allowedEngines?.count == 1 }
    public var pinsPolishModel: Bool { allowedPolishModels?.count == 1 }
    // The update check is the app's one request a user can start: off, there is none at all.
    public var allowsUpdateChecks: Bool { updateChecks != false }

    public var managedKeys: [Key] {
        Key.allCases.filter { key in
            switch key {
            case .allowedEngines: allowedEngines != nil
            case .polishDictations: polishDictations != nil
            case .allowedPolishModels: allowedPolishModels != nil
            case .learnCorrections: learnCorrections != nil
            case .clipboardMode: clipboardMode
            case .updateChecks: updateChecks != nil
            }
        }
    }
}
