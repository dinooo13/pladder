# Architecture Review

A review of the codebase as of September 2026, covering what holds up, where the pressure points are, and what to do about them. Nothing here touches the release-to-paste path; all suggestions are off-path plumbing.

## What holds up

**Ports and adapters, done properly.** `PladderCore` imports Foundation only. All I/O — capture, hotkey, output, engine, processing — sits behind five small protocols in `Sources/PladderCore/Protocols/`, and everything is injected into the coordinator. Fast tests and genuinely swappable engines fall out of this for free; the `EchoEngine` test double proves the seams are real.

**An honest composition root.** `AppModel` does all the wiring (AppModel.swift:77-141): registry, settings store, processor order, coordinator, overlay. The coordinator owns only the state machine. Processor order is defined in exactly one place, and both the settings toggles and the runtime pipeline derive from it.

**Deliberate concurrency.** Actors for engine and capture, a `@MainActor` coordinator, and an `EventRelay` that stamps events at emission time so the release-to-paste measurement excludes scheduling delay (AppModel.swift:330-338). The metric is taken seriously, and the architecture serves it rather than fighting it.

**The processing pipeline is a strategy pattern in all but name.** `TextProcessor` is the strategy interface, each processor a concrete strategy, `ProcessorPipeline` the context that runs them in sequence. Swapping or adding a strategy is one file plus one line in `processorOrder` — exactly the pattern's promise. It is more precisely a pipeline (sequential transforms over shared data) than classic strategy (one algorithm selected at a time), which is the right shape for text post-processing, and why `disabledProcessors` is a runtime filter rather than a selection.

**The architecture gets pruned, not accreted.** The documented decisions — the benchmark gate on the critical path, the removal of the Apple Intelligence cleanup step — show the design responding to measurement.

## Pressure points

All of them are inside or around `DictationCoordinator`, which is where the next refactor should happen.

1. **The coordinator is drifting toward god-object.** State machine + hotkey lifecycle + engine loading + 250 ms status polling + watchdog + error-reset timer, five task handles. Readable at 318 lines, but it is the file to watch.

2. **Status polling is the main smell.** `pollStatus(of:)` (DictationCoordinator.swift:151-162) polls the engine every 250 ms while loading. The comment justifying it is pragmatic, not principled; a status `AsyncStream` would fit the otherwise stream-based design.

3. **Settings live in the coordinator.** The `didSet` side effects in `settingsChanged` couple configuration to the state machine and force the awkward get/set forwarding in `AppModel.settings` (AppModel.swift:51-65).

4. **The `DictionaryReplacer` special case.** `makePipeline` reaches in and matches on `processor.id` to reconfigure one specific strategy with settings (AppModel.swift:129-135). That is identity-based selection leaking into the context — the strategy pattern's whole point is that the context only knows the interface. The placeholder-entry hack already needed a comment to explain itself (AppModel.swift:112-114).

5. **Minor brittleness.** `preconditionFailure` on an empty registry in the coordinator's init, and the `processed.last!` force-unwrap in `finish`. Safe today, brittle tomorrow.

## Recommended changes, in order

**1. Extract engine lifecycle from the coordinator.** Move `loadEngine`/`pollStatus`/`setEngineStatus` (DictationCoordinator.swift:121-174) into an `EngineLoader` that owns the engine reference, exposes `status: AsyncStream<EngineStatus>`, and handles load, reload, and unload-on-swap. The coordinator subscribes to the stream the way it already does for hotkey events and mic levels. This removes the poll, three of the five task handles, and shrinks the coordinator to the state machine plus wiring.

**2. Take settings out of the coordinator.** Make `Settings` an `@Observable` class owned by `AppModel` (or the `SettingsStore`), and have the coordinator consume changes instead of owning the value:

- `func applyHotkey(hotkey:submitKey:)` and `func applyEngine(_ id: EngineID)` — the `didSet` logic becomes explicit calls;
- `minimumDuration`, `appendTrailingSpace`, dictionary entries etc. are read at the point of use or snapshotted when a cycle starts.

This kills the forwarding in `AppModel.settings` — the UI binds to the settings object directly, and persistence becomes a plain side effect in the store.

**3. Make the pipeline a list of factories.** Change `processorOrder` to `[(Settings) -> any TextProcessor]` and build the pipeline with `factories.map { $0(settings) }`. `DictionaryReplacer(entries: [])` disappears, its explanatory comment disappears, and a processor that needs settings no longer requires a special case — each strategy supplies its own constructor, so the context stays ignorant of concrete strategies.

**4. Small hardening.**

- Empty registry: keep a built-in last-resort engine entry in `EngineRegistry` (or have `make` return an engine that reports `.failed("...")`) instead of `preconditionFailure` — a bad settings file then degrades to an error message rather than a crash at launch.
- `processed.last!` → `processed.last` with the `needsSpace` guard folded in.

## What not to change

Do not split the state machine itself or move hotkey handling out of the coordinator. The release-to-paste path runs straight through `hotkeyReleased` → `finish`, and keeping that in one `@MainActor` file is what makes the benchmark rule enforceable. Every change above is off-path plumbing; none of it touches the metric, so none of it requires a benchmark run — though running one anyway to confirm is cheap.
