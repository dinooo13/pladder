import PladderCore

/// The engines the app and `pladder-cli` build, in the order the settings
/// picker shows them; the first is the default for new installs. Each
/// engine's name and description are written here once, so the two cannot
/// drift apart.
///
/// `displayName` and `detail` are English. PladderEngines has no String
/// Catalog: they are keys, and the app's catalog translates them where the
/// registry is built.
public enum StandardEngines {
    /// NVIDIA Parakeet TDT 0.6B v3 through FluidAudio, transcribing while the
    /// key is held.
    public static let parakeet = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.engineID,
        displayName: "Parakeet TDT v3",
        detail: "NVIDIA Parakeet via FluidAudio, runs on the Neural Engine. ~700 MB download on first use.",
        make: { FluidAudioIncrementalEngine() }
    )

    public static let entries: [EngineRegistry.Entry] = [parakeet]

    /// The engine a fresh install and `pladder-cli` use.
    public static var defaultEntry: EngineRegistry.Entry { entries[0] }
}
