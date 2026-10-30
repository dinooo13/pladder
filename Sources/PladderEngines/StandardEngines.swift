import PladderCore

// In the picker's order; the first is the default. `displayName` and `detail` are
// English catalog keys, translated where the app builds the registry.
public enum StandardEngines {
    public static let parakeet = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.engineID,
        displayName: "Parakeet TDT v3",
        detail: "NVIDIA Parakeet via FluidAudio, runs on the Neural Engine. ~700 MB download on first use.",
        make: { FluidAudioIncrementalEngine(model: .v3) }
    )

    public static let parakeetUltra = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.ultraEngineID,
        displayName: "Parakeet Ultra",
        detail: "Moondream's post-training of Parakeet TDT v3 via FluidAudio: fewer misheard words at the same speed, runs on the Neural Engine. ~600 MB download on first use.",
        make: { FluidAudioIncrementalEngine(model: .ultra) }
    )

    public static let entries: [EngineRegistry.Entry] = [parakeetUltra, parakeet]
    public static var defaultEntry: EngineRegistry.Entry { entries[0] }
}
