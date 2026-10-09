import Foundation

// `PLADDER_SETTINGS_PATH` gives a copy launched for testing a file of its own.
// `scratch` is for the overlay demo and the screenshots, which must touch nothing real.
struct SettingsLocation {
    let settingsURL: URL
    // A test copy starts from the defaults, not from an old install.
    let migratesLegacySettings: Bool

    var dismissedCorrectionsURL: URL {
        settingsURL.deletingLastPathComponent().appending(path: "dismissed-corrections.json")
    }

    static var live: SettingsLocation {
        if let path = ProcessInfo.processInfo.environment["PLADDER_SETTINGS_PATH"], !path.isEmpty {
            return SettingsLocation(settingsURL: URL(filePath: path), migratesLegacySettings: false)
        }
        return SettingsLocation(settingsURL: applicationSupport.appending(path: "Pladder/settings.json"),
                                migratesLegacySettings: true)
    }

    static var scratch: SettingsLocation {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pladder-dev-\(ProcessInfo.processInfo.processIdentifier)")
        return SettingsLocation(settingsURL: directory.appending(path: "settings.json"), migratesLegacySettings: false)
    }

    private static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    // `SpeakUp` was the app's name before Pladder. Copied once; the old file stays.
    func migrateLegacySettingsIfNeeded() {
        guard migratesLegacySettings, !FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let legacy = Self.applicationSupport.appending(path: "SpeakUp/settings.json")
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: legacy, to: settingsURL)
    }
}
