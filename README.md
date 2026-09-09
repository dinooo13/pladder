# SpeakUp

Minimal push-to-talk dictation for macOS. Hold Right Option, speak, release. The
text lands in whatever app has focus. Everything runs on this Mac: NVIDIA
Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) on
the Neural Engine, a user dictionary for names and jargon, and an optional Apple
Intelligence cleanup pass. No cloud, no accounts.

Requires macOS 26 on Apple Silicon.

## Build and run

```sh
./scripts/bundle.sh --run      # release build, assembles and signs dist/SpeakUp.app, launches it
swift test                     # unit tests (core state machine, dictionary, audio conversion)
swift run speakup-cli file.wav # transcribe a file from the terminal to check the engine
```

The first launch downloads about 700 MB of CoreML models into
`~/Library/Application Support/FluidAudio/Models`. The menu bar icon shows
progress and the hotkey stays disabled until the model is ready.

### Permissions

SpeakUp needs two permissions, both requested on first launch:

- **Microphone**, to record while the key is held.
- **Accessibility**, for the global hotkey and for pasting into other apps.

macOS ties both grants to the app's code signature. The bundle script signs with
your Apple Development or Developer ID certificate when one is in the keychain,
so rebuilds keep their permissions. With no certificate it falls back to an
ad-hoc signature, which changes every build and makes macOS ask again. Force a
specific identity with `CODESIGN_IDENTITY="Developer ID Application: …"` or
`CODESIGN_IDENTITY=-` for ad-hoc.

## Layout

```
Sources/
  SpeakUpCore/     protocols, models, state machine, dictionary. Foundation only.
  SpeakUpAudio/    AVAudioEngine capture, resampling to 16 kHz mono, level meter
  SpeakUpEngines/  FluidAudioEngine (Parakeet). Add new engines here.
  SpeakUpSystem/   global hotkey, pasteboard paste, permissions, Foundation Models processor
  SpeakUp/         the menu bar app: composition root, overlay pill, settings
  SpeakUpCLI/      developer tool for transcribing files
Tests/             Swift Testing suites for Core and Audio
scripts/bundle.sh  builds and signs dist/SpeakUp.app
```

## Adding an engine

1. Implement `TranscriptionEngine` (an actor) in `Sources/SpeakUpEngines/`.
   `load()` should download and warm the model and report progress through
   `status`; `transcribe(_:)` takes 16 kHz mono Float32 samples.
2. Register it in `AppModel.init` with an `EngineRegistry.Entry`. The settings
   picker and the coordinator read the registry; nothing else changes.

## Adding a text processor

1. Implement `TextProcessor` with a stable `id`.
2. Append it to the `ProcessorPipeline` in `AppModel.init` in the position you
   want it to run.
3. Add a toggle row in `SettingsView`'s Processing tab if it should be optional.
   Toggles work by adding the `id` to `Settings.disabledProcessors`.

See `PLAN.md` for the design notes and the decisions behind them.
