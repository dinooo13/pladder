import Foundation
import Testing
@testable import PladderCore

@Suite struct SettingsStoreTests {
    @Test func everyStoredKeyRoundTripsThroughTheFile() throws {
        try withStore { store, _ in
            #expect(store.load() == Self.defaults)
            var settings = Self.defaults
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
            try store.save(settings)
            #expect(store.load() == settings)
        }
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"engineID":"echo","dictionary":[{"id":"6E36117C-6200-4C7E-BFB8-6FA228542578","from":"a","to":"b","matchCase":false}]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        var expected = Self.defaults
        expected.dictionary = decoded.dictionary
        #expect(decoded.dictionary.count == 1)
        #expect(decoded == expected)
    }

    @Test func legacyPolishChordMigratesToTheToggle() throws {
        let json = #"{"engineID":"echo","polishHotkey":{"keyCodes":[59,31]}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.polishDictations)
        // The toggle stays off over a legacy chord stored empty.
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"engineID":"echo","polishHotkey":{"keyCodes":[]}}"#.utf8))
        #expect(!off.polishDictations)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        try withStore(file: "not json") { store, url in
            _ = store.load()
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(Self.backups(beside: url).count == 1)
        }
    }

    // MARK: Lenient decoding (a throw moves the file aside and empties the dictionary)

    private static let entryJSON = #"{"id":"6E36117C-6200-4C7E-BFB8-6FA228542578","from":"a","to":"b","matchCase":false}"#

    @Test(arguments: ["appearance", "overlayStyle", "overlayAnimationSpeed", "polishModel"])
    func anUnknownCaseKeepsItsDefaultAndTheRest(key: String) throws {
        let json = #"{"engineID":"echo","polishDictations":true,"\#(key)":"someFutureCase","dictionary":[\#(Self.entryJSON)]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let defaults = Self.defaults
        #expect(decoded.polishDictations)
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
        let json = #"{"engineID":"echo","appearance":"someFutureCase","dictionary":[\#(Self.entryJSON)]}"#
        try withStore(file: json) { store, url in
            #expect(store.load().dictionary.count == 1)
            // The original stays where it is; the copy is the safety net for the
            // next save, which writes the default over the dropped value.
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(Self.backups(beside: url).count == 1)
        }
    }

    @Test func aCleanFileLeavesNoCopy() throws {
        try withStore { store, url in
            try store.save(Self.defaults)
            _ = store.load()
            #expect(Self.backups(beside: url).isEmpty)
        }
    }

    @Test func aSecondBrokenFileDoesNotReplaceTheFirstBackup() throws {
        try withStore(file: "not json") { store, url in
            _ = store.load()
            try Data("[]".utf8).write(to: url)
            _ = store.load()
            let contents = try Self.backups(beside: url).map { try String(contentsOf: $0, encoding: .utf8) }
            #expect(Set(contents) == ["not json", "[]"])
        }
    }

    // MARK: Keys this build does not know

    @Test func savingKeepsKeysANewerBuildWrote() throws {
        try withStore(file: #"{"engineID":"echo","someFutureSetting":{"on":true},"playSounds":false}"#) { store, url in
            var settings = store.load()
            settings.appearance = .dark
            try store.save(settings)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect((object["someFutureSetting"] as? [String: Bool]) == ["on": true])
            #expect(store.load() == settings)
            #expect(store.load().appearance == .dark)
        }
    }

    @Test func savingDropsRetiredKeys() throws {
        try withStore(file: #"{"engineID":"echo","launchAtLogin":true,"polishHotkey":{"keyCodes":[59,31]}}"#) { store, url in
            let settings = store.load()
            #expect(settings.polishDictations)
            try store.save(settings)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["launchAtLogin"] == nil)
            #expect(object["polishHotkey"] == nil)
            // The migration's result is what is stored now.
            #expect(object["polishDictations"] as? Bool == true)
        }
    }

    private static let defaults = Settings(engineID: EchoEngine.engineID)

    private func withStore(file contents: String? = nil, _ body: (SettingsStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let contents { try Data(contents.utf8).write(to: url) }
        try body(SettingsStore(url: url, defaults: Self.defaults), url)
    }

    private static func backups(beside file: URL) -> [URL] {
        let dir = file.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".broken-") }.map { dir.appendingPathComponent($0) }
    }
}
