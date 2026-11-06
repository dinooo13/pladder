import PladderCore

// In the picker's order; the first is the default. `displayName` and `detail` are
// English catalog keys, translated where the app builds the registry.
public enum StandardEngines {
    public static let parakeet = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.engineID,
        displayName: "Parakeet TDT v3",
        detail: "A little less accurate. 700 MB.",
        make: { FluidAudioIncrementalEngine(model: .v3) }
    )

    public static let parakeetUltra = EngineRegistry.Entry(
        id: FluidAudioIncrementalEngine.ultraEngineID,
        displayName: "Parakeet Ultra",
        detail: "Most accurate. 600 MB.",
        make: { FluidAudioIncrementalEngine(model: .ultra) }
    )

    public static let entries: [EngineRegistry.Entry] = [parakeetUltra, parakeet]
    public static var defaultEntry: EngineRegistry.Entry { entries[0] }
}
