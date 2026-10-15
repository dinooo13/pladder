import PladderCore

// In the picker's order; the first is the default. `displayName` and `detail` are
// English catalog keys, translated where the app builds the registry.
public enum StandardEngines {
    public static let parakeet = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.engineID,
        displayName: "Parakeet TDT v3",
        detail: "NVIDIA Parakeet via FluidAudio, runs on the Neural Engine. ~700 MB download on first use.",
        make: { FluidAudioIncrementalEngine() }
    )

    public static let entries: [EngineRegistry.Entry] = [parakeet]
    public static var defaultEntry: EngineRegistry.Entry { entries[0] }
}
