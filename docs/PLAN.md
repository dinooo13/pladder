# SpeakUp — implementation plan

Minimal push-to-talk dictation for macOS. Hold a key, speak, release, text lands in
the frontmost app. Local only: Parakeet via FluidAudio, a user dictionary for
replacements, no cloud. An optional on-device Apple Foundation Models cleanup step
sits behind the same processor interface and is off by default.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Platform | macOS 26+, Apple Silicon only | FluidAudio needs the Neural Engine; Foundation Models needs 26 |
| Distribution | Direct, not sandboxed, not App Store | Global hotkey + synthetic paste do not work sandboxed |
| Language | Swift 6.3, strict concurrency, SwiftUI | Current toolchain on this machine |
| Build | SwiftPM package + `scripts/bundle.sh` that wraps the binary in `SpeakUp.app` | No Xcode project file to maintain, opens in Xcode via `Package.swift`. XcodeGen is the fallback if we want Xcode-native debugging later |
| Engine | FluidAudio, Parakeet TDT 0.6B v3 | Fastest Swift-native option, runs on ANE |
| Hotkey | Hold **Right Command** by default; any key or chord can be recorded | A CGEvent tap (Accessibility, no Input Monitoring) matches the chord and swallows its regular key so it never reaches the target app |
| Output | Clipboard + simulated Cmd+V, restore old clipboard | Universal, fast |
| Post-processing | Dictionary replacer only by default | No latency, no network |

## Architecture

Everything the coordinator touches is a protocol. Concrete implementations live in
separate modules so swapping the engine means adding one file and one registry line.

```
speakup/
  Package.swift
  Sources/
    SpeakUpCore/          pure logic, no Apple frameworks beyond Foundation
      Protocols/
        TranscriptionEngine.swift   load(), transcribe([Float]) -> Transcript, isReady
        AudioCapture.swift          start() -> AsyncStream<level>, stop() -> CapturedAudio
        TextProcessor.swift         process(String) async -> String
        TextOutput.swift            insert(String) async throws
        HotkeyMonitor.swift         events: AsyncStream<HotkeyEvent> (.pressed/.released); Hotkey = chord of key codes
      HotkeyChordTracker.swift      pure press/release state machine for a chord
      Models/
        Transcript.swift            text, language, duration, engineID
        DictationState.swift        idle / recording(level) / transcribing / inserting / error
        Settings.swift              Codable, engine ID, hotkey, processor toggles
        DictionaryEntry.swift       from, to, matchCase
      DictationCoordinator.swift    the state machine, @MainActor @Observable
      Processors/
        DictionaryReplacer.swift    whole-word, case-aware replacement
        WhitespaceNormalizer.swift
        ProcessorPipeline.swift     runs an ordered [TextProcessor]
      EngineRegistry.swift          id -> factory, drives the settings picker
    SpeakUpAudio/
      AVAudioEngineCapture.swift    mic tap, AVAudioConverter to 16 kHz mono Float32, RMS level
    SpeakUpEngines/
      FluidAudioEngine.swift        depends on FluidAudio; actor; model warm-up + download progress
      (later) AppleSpeechEngine.swift, WhisperKitEngine.swift
    SpeakUpSystem/
      PasteboardOutput.swift        NSPasteboard + CGEvent Cmd+V
      GlobalHotkeyMonitor.swift     CGEvent tap feeding HotkeyChordTracker; swallows the chord's regular key
      Permissions.swift             mic + accessibility checks and prompts
      FoundationModelProcessor.swift  optional, FoundationModels framework, availability-gated
    SpeakUp/                        the app target
      SpeakUpApp.swift              @main, MenuBarExtra, wires dependencies
      Overlay/
        OverlayPanel.swift          non-activating floating NSPanel
        OverlayView.swift           SwiftUI: level meter, transcribing spinner, error
      Settings/
        SettingsView.swift          engine picker, hotkey, processor toggles
        DictionaryView.swift        editable table, import/export JSON
  Tests/
    SpeakUpCoreTests/
      DictionaryReplacerTests.swift
      DictationCoordinatorTests.swift   uses fake engine, fake output, fake capture
  scripts/
    bundle.sh                       builds release, assembles SpeakUp.app, signs with a developer certificate when available
```

### Data flow

```
hotkey pressed  -> capture.start(), overlay shows meter, state = .recording
hotkey released -> samples = capture.stop(), state = .transcribing
                -> engine.transcribe(samples)
                -> pipeline.process(text)      (dictionary, whitespace, optional FM)
                -> output.insert(text), state = .inserting, overlay dismisses
```

The coordinator owns the state machine and nothing else. It receives every
dependency through its initializer, so tests run it with in-memory fakes and the app
runs it with the real modules.

### Pluggability rules

- `SpeakUpCore` imports only Foundation. It never imports FluidAudio, AVFoundation
  or AppKit, so tests compile fast and engines are truly swappable.
- Adding an engine: implement `TranscriptionEngine`, register in `EngineRegistry`,
  done. The settings picker reads the registry.
- Adding a processor: implement `TextProcessor`, append to the pipeline in
  `SpeakUpApp`. Order is explicit and visible in one place.
- Engine, capture, and Foundation Models are actors. The coordinator is `@MainActor`
  because it drives UI.

## Milestones

1. **Skeleton, fake engine.** Package, modules, protocols, coordinator, menu bar
   item, hotkey, overlay panel, paste output. Engine is an `EchoEngine` returning
   fixed text. Goal: hold key, release, "hello world" appears in TextEdit. Proves
   permissions, hotkey, overlay and paste before any ML is involved.
2. **Real audio and Parakeet.** `AVAudioEngineCapture` with conversion and level
   meter, `FluidAudioEngine` with warm-up on launch and download progress in the
   menu. Goal: real dictation end to end.
3. **Dictionary and settings.** `DictionaryReplacer` with tests, dictionary editor,
   settings window, engine picker backed by the registry, JSON persistence in
   Application Support.
4. **Polish and optional Foundation Models.** Overlay animation and error states,
   launch at login, `FoundationModelProcessor` behind a toggle with an availability
   check, `bundle.sh` producing a signed app.

## Risks and how they are handled

- **Audio format.** Mic delivers 48 kHz, Parakeet wants 16 kHz mono Float32.
  Conversion is isolated in `AVAudioEngineCapture` and verified with a recorded
  fixture in milestone 2.
- **First launch.** FluidAudio downloads a few hundred MB from Hugging Face and
  CoreML compiles on first load. The menu shows progress and the hotkey is disabled
  until `engine.isReady`.
- **Cold latency.** Engine loads at launch and stays resident. The audio engine is
  prepared at launch and only runs while the key is held, so the system
  microphone indicator is off when idle.
- **Clipboard clobbering.** Output saves the pasteboard, pastes, then restores it
  after a short delay.
- **Permissions.** Mic prompt fires on first record, Accessibility is checked at
  launch with a menu item that opens System Settings. Both need a proper bundle
  identifier and signature, which `bundle.sh` supplies.
- **Foundation Models latency.** Roughly a second per utterance, so it is opt-in and
  runs after the dictionary step.

## Status (2026-09-09)

All four milestones are implemented and committed. Verified on this Mac:

- 34 unit tests pass (`swift test`): state machine, dictionary replacer, settings
  migration, audio resampling and level metering.
- Parakeet transcribes a synthesized 6 s clip in about 180 ms via `speakup-cli`.
- Full push-to-talk cycle observed end to end: simulated Right Option hold,
  overlay pill with level meter, Parakeet transcription of live microphone audio,
  paste into TextEdit with trailing space.
- Idle state no longer holds the microphone, so the orange system recording
  indicator only shows while the key is held.
- Settings window: engine and hotkey pickers, dictionary editor with examples,
  import/export and live preview, processor toggles; settings persist as JSON.
- A Fable review pass found four correctness issues (settings wiped on schema
  change, mic left on when settings change mid-recording, hotkey events queued
  during transcription, pasteboard restore on the critical path). All fixed and
  covered by tests.

Not verifiable here: the Apple Intelligence cleanup step, because Apple
Intelligence is switched off on this machine. It falls through and returns the
text unchanged, which is the tested path.

## Out of scope for now

Cloud models, streaming partial results, multiple simultaneous engines, App Store,
iOS.
