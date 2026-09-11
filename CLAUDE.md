# SpeakUp

Push-to-talk dictation for macOS 26 on Apple Silicon. Hold a key, speak, release, and the words are pasted where the cursor is. Everything runs on the Mac.

## What the project optimises for

1. **Speed of the release-to-paste path.** This is the metric. The path runs from the hotkey release to the paste: capture stop, engine, processors, output. In code it is everything between the coordinator's `recordingStopped` and `inserted` events. Nothing goes on that path without a before-and-after benchmark.
2. **Minimal UI.** No new settings, windows or overlay elements unless a feature cannot work without them. Prefer removing to adding.
3. **On-device processing and privacy.** Audio and text never leave the Mac. No network calls, no telemetry, no accounts. The one-time model download from Hugging Face is the only exception and stays the only one.

## Critical-path rule

Before and after any change that touches the code between `recordingStopped` and `inserted` in `DictationCoordinator`, run the benchmark and put both results in the pull request. The procedure and the M1 baseline are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md). A difference under about ten percent is noise. The app also logs the release-to-paste time of every real dictation:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.beh.speakup"'
```

## Commands

```sh
swift build                                   # debug build of everything
swift test                                    # unit tests, well under a second
./scripts/bundle.sh [--run] [--install]       # release build → dist/SpeakUp.app, signed
swift run -c release speakup-cli <audio file> # transcribe one file, print timing
./scripts/make-fixtures.sh                    # synthesise benchmark fixtures into bench/fixtures (gitignored)
swift run -c release speakup-cli bench bench/fixtures   # run the benchmark
```

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Platform | macOS 26+, Apple Silicon only | FluidAudio needs the Neural Engine |
| Distribution | Direct, not sandboxed, not App Store | Global hotkey and synthetic paste do not work sandboxed |
| Language | Swift 6.2 tools, strict concurrency, SwiftUI | Current toolchain |
| Build | SwiftPM package + `scripts/bundle.sh` wrapping the binary in `SpeakUp.app` | No Xcode project to maintain; `Package.swift` opens in Xcode |
| Engine | FluidAudio, Parakeet TDT 0.6B v3 | Fastest Swift-native option, runs on the Neural Engine |
| Hotkey | Hold Right Command by default; any key or chord can be recorded | A CGEvent tap (Accessibility, no Input Monitoring) matches the chord and swallows its regular key so it never reaches the target app |
| Output | Clipboard + simulated Cmd+V; the old clipboard is restored off the critical path | Universal, fast |
| Post-processing | Dictionary replacer and whitespace normaliser only | No latency, no network. The Apple Intelligence cleanup step was removed because it sat on the critical path without anyone measuring what it cost |
| Recording cap | 120 s | Keeps the microphone from staying on when a key-up is lost |
| Benchmark | A script run by hand, not a test | A benchmark that fails on noise gets ignored |

## Pluggability rules

- `SpeakUpCore` imports Foundation only. It never imports FluidAudio, AVFoundation or AppKit, so tests compile fast and engines are truly swappable.
- Adding an engine: implement `TranscriptionEngine` in its own file under `SpeakUpEngines`, register it in the `EngineRegistry` built in `AppModel`. One file plus one registry line; the settings picker reads the registry.
- Adding a processor: implement `TextProcessor` in its own file, append it to `processorOrder` in `AppModel`. The order is explicit and visible in one place. A processor sits on the critical path, so the benchmark rule applies.
- Engine and capture are actors. The coordinator is `@MainActor` because it drives UI. It owns the state machine and nothing else; every dependency is injected, so tests run it with in-memory fakes.

## Risks

- **Audio format.** The microphone delivers 48 kHz; the engine wants 16 kHz mono Float32. Conversion is isolated in `AudioResampler` and unit tested against synthesised buffers.
- **First launch.** About 700 MB of CoreML models download from Hugging Face and compile on first load. The menu shows progress and the hotkey is disabled until the engine is ready.
- **Cold latency.** The engine loads at launch and stays resident. The audio engine is prepared at launch and runs only while the key is held, so the system microphone indicator is off when idle.
- **Long recordings.** FluidAudio's encoder window is 15 s. Longer audio is split into 15 s windows with 2 s overlap and stitched; seams can drop or duplicate words, which FluidAudio's own notes flag for the v3 model. The 30 s to 10 min fixtures watch for this.
- **Clipboard clobbering.** Output saves the pasteboard, pastes, and restores it after a short delay.
- **Permissions.** Accessibility and Microphone grants are keyed to the code signature. `bundle.sh` signs with an Apple Development or Developer ID certificate when one is in the keychain; an ad-hoc signature changes on every build and resets both grants.
- **Lost key-up.** When the 120 s watchdog fires, the coordinator transcribes and pastes as if the user had released. Discarding is probably the right behaviour; tracked separately.

## Working on this Mac while SpeakUp is in use

The developer dictates with a running SpeakUp all day, often into Claude sessions, and several worktrees may each have their own `dist/SpeakUp.app`.

- Never `pkill -x SpeakUp` or `killall SpeakUp`: that also kills the copy in use, mid-recording, and the text is lost. Stop only the copy you launched: `pkill -f "$PWD/dist/SpeakUp.app"`.
- Do not post synthetic hotkey events unless the user has asked for a live UI test. Every running copy reacts to them, so they start, cut short, or paste the user's recordings.
- Do not edit `~/Library/Application Support/SpeakUp/settings.json`; it is the live configuration.
