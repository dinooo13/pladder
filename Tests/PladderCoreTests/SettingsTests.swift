import Foundation
import Testing
@testable import PladderCore

@Suite struct SettingsStoreTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        #expect(store.load() == defaults)

        var changed = defaults
        changed.hotkey = .rightOption
        changed.submitKey = Hotkey(0x24)
        changed.polishDictations = true
        changed.dictionary = [DictionaryEntry(from: "a", to: "b")]
        try store.save(changed)
        #expect(store.load() == changed)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"engineID":"echo","dictionary":[{"id":"6E36117C-6200-4C7E-BFB8-6FA228542578","from":"a","to":"b","matchCase":false}]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.engineID == EchoEngine.engineID)
        #expect(decoded.dictionary.count == 1)
        #expect(decoded.hotkey == .optionSpace)
        #expect(decoded.submitKey == .keyV)
        #expect(!decoded.polishDictations)
        #expect(decoded.polishModel == .appleIntelligence)
        #expect(decoded.appendTrailingSpace == true)
        #expect(decoded.appearance == .system)
        #expect(decoded.overlayStyle == .compact)
        #expect(decoded.overlayGlass == true)
        #expect(decoded.overlayAnimationSpeed == .quick)
    }

    @Test func legacyPolishChordMigratesToTheToggle() throws {
        let json = #"{"engineID":"echo","polishHotkey":{"keyCodes":[59,31]}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.polishDictations)
        // The toggle stays off over a legacy chord stored empty.
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"engineID":"echo","polishHotkey":{"keyCodes":[]}}"#.utf8))
        #expect(!off.polishDictations)
    }

    @Test func polishModelPersists() throws {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.polishModel = .s1Mini8Bit
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.polishModel == .s1Mini8Bit)
    }

    @Test func anUnknownPolishModelFallsBackToApples() throws {
        // Written by a newer build that knows a model this one does not.
        let json = #"{"engineID":"echo","polishDictations":true,"polishModel":"someFutureModel"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.polishModel == .appleIntelligence)
        #expect(decoded.polishDictations)
    }

    @Test func appearancePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        var changed = defaults
        changed.appearance = .dark
        try store.save(changed)
        #expect(store.load() == changed)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func overlayStylePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        var changed = defaults
        changed.overlayStyle = .minimal
        changed.overlayGlass = false
        try store.save(changed)
        #expect(store.load() == changed)

        changed.overlayStyle = .liveTranscript
        try store.save(changed)
        #expect(store.load() == changed)
        #expect(store.load().overlayStyle == .liveTranscript)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func overlayAnimationSpeedPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let defaults = Settings(engineID: EchoEngine.engineID)
        let store = SettingsStore(url: url, defaults: defaults)
        var changed = defaults
        changed.overlayAnimationSpeed = .expressive
        try store.save(changed)
        #expect(store.load() == changed)

        changed.overlayAnimationSpeed = .instant
        try store.save(changed)
        #expect(store.load().overlayAnimationSpeed == .instant)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        _ = store.load()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(Self.backups(in: dir).count == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Lenient decoding (a throw moves the file aside and empties the dictionary)

    private static let entryJSON = #"{"id":"6E36117C-6200-4C7E-BFB8-6FA228542578","from":"a","to":"b","matchCase":false}"#

    @Test(arguments: ["appearance", "overlayStyle", "overlayAnimationSpeed", "polishModel"])
    func anUnknownCaseKeepsItsDefaultAndTheRest(key: String) throws {
        let json = #"{"engineID":"echo","\#(key)":"someFutureCase","dictionary":[\#(Self.entryJSON)]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let defaults = Settings(engineID: EchoEngine.engineID)
        #expect(decoded.appearance == defaults.appearance)
        #expect(decoded.overlayStyle == defaults.overlayStyle)
        #expect(decoded.overlayAnimationSpeed == defaults.overlayAnimationSpeed)
        #expect(decoded.polishModel == defaults.polishModel)
        #expect(decoded.dictionary.map(\.to) == ["b"])
    }

    @Test func aDamagedDictionaryRowIsDroppedAndTheOthersKept() throws {
        let json = #"{"engineID":"echo","dictionary":[\#(Self.entryJSON),{"from":3},{"from":"c","to":"d"}]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.dictionary.map(\.to) == ["b", "d"])
    }

    @Test func aRowWithoutIDOrMatchCaseIsRead() throws {
        let json = #"{"engineID":"echo","dictionary":[{"from":"c","to":"d"}]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.dictionary.count == 1)
        #expect(decoded.dictionary[0].matchCase == false)
    }

    @Test func aMissingEngineDecodesAndIsLeftForTheAppToRepair() throws {
        let json = #"{"dictionary":[\#(Self.entryJSON)],"playSounds":false}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.engineID == EngineID(""))
        #expect(decoded.dictionary.count == 1)
        #expect(!decoded.playSounds)
    }

    @Test func aWrongTypeKeepsTheDefault() throws {
        let json = #"{"engineID":"echo","hotkey":"option space","playSounds":"yes","submitKey":{"keyCodes":[]}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.hotkey == .optionSpace)
        #expect(decoded.playSounds)
        #expect(decoded.submitKey.keyCodes.isEmpty)
    }

    @Test func aFileWithSomethingDroppedLoadsAndIsCopiedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"engineID":"echo","appearance":"someFutureCase","dictionary":[\#(Self.entryJSON)]}"#
        try Data(json.utf8).write(to: url)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        #expect(store.load().dictionary.count == 1)
        // The original stays where it is; the copy is the safety net for the
        // next save, which writes the default over the dropped value.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(Self.backups(in: dir).count == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aCleanFileLeavesNoCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        try store.save(Settings(engineID: EchoEngine.engineID))
        _ = store.load()
        #expect(Self.backups(in: dir).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aSecondBrokenFileDoesNotReplaceTheFirstBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        try Data("not json".utf8).write(to: url)
        _ = store.load()
        try Data("[]".utf8).write(to: url)
        _ = store.load()
        let contents = try Self.backups(in: dir).map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(Set(contents) == ["not json", "[]"])
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Keys this build does not know

    @Test func savingKeepsKeysANewerBuildWrote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"engineID":"echo","someFutureSetting":{"on":true},"playSounds":false}"#.utf8).write(to: url)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        var settings = store.load()
        settings.appearance = .dark
        try store.save(settings)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((object["someFutureSetting"] as? [String: Bool]) == ["on": true])
        #expect(store.load() == settings)
        #expect(store.load().appearance == .dark)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func savingDropsRetiredKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"engineID":"echo","launchAtLogin":true,"polishHotkey":{"keyCodes":[59,31]}}"#.utf8).write(to: url)
        let store = SettingsStore(url: url, defaults: Settings(engineID: EchoEngine.engineID))
        let settings = store.load()
        #expect(settings.polishDictations)
        try store.save(settings)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["launchAtLogin"] == nil)
        #expect(object["polishHotkey"] == nil)
        // The migration's result is what is stored now.
        #expect(object["polishDictations"] as? Bool == true)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func everyStoredKeyRoundTrips() throws {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.hotkey = .rightOption
        settings.submitKey = Hotkey(keyCodes: [])
        settings.polishDictations = true
        settings.polishModel = .s1Mini
        settings.toggleHotkey = .optionSpace
        settings.disabledProcessors = ["fillers", "dictionary"]
        settings.dictionary = [DictionaryEntry(from: "a", to: "b", matchCase: true)]
        settings.appendTrailingSpace = false
        settings.playSounds = false
        settings.muteOutputWhileDictating = true
        settings.appearance = .light
        settings.overlayStyle = .menuBar
        settings.overlayGlass = false
        settings.overlayAnimationSpeed = .instant
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    private static func backups(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".broken-") }.map { dir.appendingPathComponent($0) }
    }
}
