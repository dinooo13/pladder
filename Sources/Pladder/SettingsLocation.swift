import Foundation

/// Where the app keeps its files.
///
/// `live` is the user's configuration, unless `PLADDER_SETTINGS_PATH` points
/// a copy launched for testing at a file of its own, so it neither reads nor
/// writes the configuration of the copy in daily use. `scratch` is a
/// throwaway directory for the overlay demo and the screenshots, which must
/// never read, move aside or write anything real.
struct SettingsLocation {
    let settingsURL: URL
    /// Whether the pre-rename settings are copied across when there are none
    /// yet. Only for the real configuration: a test copy starts from the
    /// defaults, not from an old install.
    let migratesLegacySettings: Bool

    /// The corrections the user dismissed, beside the settings but not in
    /// them (see `DismissedCorrections`).
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

    /// One-time migration from the pre-rename location. The dictionary and
    /// hotkey settings were kept in `~/Library/Application Support/SpeakUp/`
    /// before the app was called Pladder; copy them across exactly once, only
    /// when the new file does not exist yet. The old file is left in place.
    func migrateLegacySettingsIfNeeded() {
        guard migratesLegacySettings, !FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let legacy = Self.applicationSupport.appending(path: "SpeakUp/settings.json")
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: legacy, to: settingsURL)
    }
}
