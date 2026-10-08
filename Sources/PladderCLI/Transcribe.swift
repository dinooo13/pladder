import Foundation
import PladderCore
import PladderEngines
import PladderSystem

/// The app's settings, for `--process`. Decoded here rather than through
/// `SettingsStore.load()`, which moves a file it cannot decode aside: a CLI
/// built from another branch must never touch the live configuration.
func appSettings() -> Settings {
    let url = ProcessInfo.processInfo.environment["PLADDER_SETTINGS_PATH"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pladder/settings.json")
    let fallback = Settings(engineID: StandardEngines.defaultEntry.id)
    guard let data = try? Data(contentsOf: url) else { return fallback }
    do {
        return try JSONDecoder().decode(Settings.self, from: data)
    } catch {
        eprint("pladder-cli: \(url.path): \(error); processing with the defaults")
        return fallback
    }
}

func transcribeFile(_ path: String, process: Bool, verbose: Bool) async {
    do {
        let engine = makeEngine()
        let loadTime = try await loadEngine(engine)
        if verbose { print(String(format: "model ready in %.1fs", loadTime.timeInterval)) }

        let samples = try loadSamples(URL(fileURLWithPath: path))
        let transcript = try await engine.transcribe(samples)
        var text = transcript.text
        if process {
            let settings = DictationSettings(appSettings())
            let pipeline = StandardProcessors.pipeline(for: settings, onFailure: { id, error in
                eprint("pladder-cli: processor \(id) failed: \(error)")
            })
            text = await pipeline.run(text, disabled: settings.disabledProcessors)
        }
        if verbose {
            print(String(format: "audio %.2fs, processed in %.3fs (%.0fx realtime)", transcript.audioDuration, transcript.processingTime, transcript.realtimeFactor))
            if process { print("RAW: \(transcript.text)") }
            print("TEXT: \(text)")
        } else {
            print(text)
        }
    } catch {
        // A file Core Audio cannot open (WebM, say) is the likely failure; a
        // message and a status rather than a trap, for whatever called us.
        eprint("pladder-cli: \(path): \(error)")
        exit(1)
    }
}
