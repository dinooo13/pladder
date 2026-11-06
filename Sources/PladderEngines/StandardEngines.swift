import PladderCore

// In the picker's order; the first is the default. `displayName` and `detail` are
// English catalog keys, translated where the app builds the registry.
public enum StandardEngines {
    public static let parakeet = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.engineID,
        displayName: "Parakeet TDT v3",
        detail: "NVIDIA’s Parakeet, on the Neural Engine. A one-time 700 MB download.",
        make: { FluidAudioIncrementalEngine(model: .v3) }
    )

    public static let parakeetUltra = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.ultraEngineID,
        displayName: "Parakeet Ultra",
        detail: "Recommended. Parakeet v3 retrained by Moondream: a fifth fewer misheard words at the same speed. A one-time 600 MB download.",
        make: { FluidAudioIncrementalEngine(model: .ultra) }
    )

    public static let entries: [EngineRegistry.Entry] = [parakeetUltra, parakeet]
    public static var defaultEntry: EngineRegistry.Entry { entries[0] }
}
