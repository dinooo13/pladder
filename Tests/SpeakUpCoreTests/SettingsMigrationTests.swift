import Foundation
import Testing
@testable import SpeakUpCore

/// The cleanup step used to be a processor toggled through
/// `disabledProcessors`. These pin the one-way migration onto the
/// `cleanupEnabled` / `cleanupProviderID` pair.
@Suite struct SettingsMigrationTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func legacyDisabledStaysOff() throws {
        let s = try decode(#"{"engineID":"echo","disabledProcessors":["foundation-model"]}"#)
        #expect(s.cleanupEnabled == false)
        #expect(s.cleanupProviderID == "apple-intelligence")
        #expect(s.disabledProcessors.isEmpty)
    }

    @Test func legacyEnabledMigratesOn() throws {
        let s = try decode(#"{"engineID":"echo","disabledProcessors":["whitespace"]}"#)
        #expect(s.cleanupEnabled == true)
        #expect(s.disabledProcessors == ["whitespace"])
    }

    @Test func absentDisabledKeyMigratesOn() throws {
        let s = try decode(#"{"engineID":"echo"}"#)
        #expect(s.cleanupEnabled == true)
    }

    @Test func explicitKeyWinsOverLegacy() throws {
        let off = try decode(#"{"engineID":"echo","cleanupEnabled":false,"disabledProcessors":[]}"#)
        #expect(off.cleanupEnabled == false)

        let on = try decode(#"{"engineID":"echo","cleanupEnabled":true,"disabledProcessors":["foundation-model"]}"#)
        #expect(on.cleanupEnabled == true)
        #expect(on.disabledProcessors.isEmpty)
    }

    @Test func providerIDDefaultsWhenAbsent() throws {
        let s = try decode(#"{"engineID":"echo","cleanupEnabled":true}"#)
        #expect(s.cleanupProviderID == Settings.defaultCleanupProviderID)
    }

    @Test func roundTripPersistsCleanupFields() throws {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.cleanupEnabled = true
        settings.cleanupProviderID = "other"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.cleanupEnabled == true)
        #expect(decoded.cleanupProviderID == "other")
    }

    @Test func encodeNeverWritesLegacyID() throws {
        let migrated = try decode(#"{"engineID":"echo","disabledProcessors":["foundation-model","whitespace"]}"#)
        let json = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        #expect(!json.contains(Settings.legacyFoundationModelProcessorID))
        #expect(json.contains("whitespace"))
    }
}
