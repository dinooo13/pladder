# Pladder

Push-to-talk dictation for macOS 26 on Apple Silicon. Hold a key, speak, release, and the words are pasted where the cursor is. Everything runs on the Mac.

## What the project optimises for

1. **Speed of the release-to-paste path.** This is the metric. The path runs from the hotkey release to the paste: capture stop, engine, processors, output. In code it is everything between the coordinator's `recordingStopped` and `inserted` events. Nothing goes on that path without a before-and-after benchmark.
2. **Minimal UI.** No new settings, windows or overlay elements unless a feature cannot work without them. Prefer removing to adding.
3. **On-device processing and privacy.** Audio and text never leave the Mac. No network calls, no telemetry, no accounts. The one-time model download from Hugging Face is the only exception and stays the only one.

## Critical-path rule

Before and after any change that touches the code between `recordingStopped` and `inserted` in `DictationCoordinator`, run the benchmark and put both results in the pull request. The procedure and the M1 baseline are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md). A difference under about ten percent is noise. The app also logs the release-to-paste time of every real dictation:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```

## Commands

```sh
swift build                                   # debug build of everything
swift test                                    # unit tests, well under a second
./scripts/bundle.sh [--run] [--install]       # release build → dist/Pladder.app, signed
swift run -c release pladder-cli <audio file> # transcribe one file, print timing
./scripts/make-fixtures.sh                    # synthesise benchmark fixtures into bench/fixtures (gitignored)
swift run -c release pladder-cli bench bench/fixtures            # whole-buffer benchmark
swift run -c release pladder-cli bench bench/fixtures --paced     # feed at real time, time endUtterance, check identity
swift run -c release pladder-cli polish <text file>   # run the polish prompt over a transcript, print both timings
```

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Platform | macOS 26+, Apple Silicon only | FluidAudio needs the Neural Engine |
| Distribution | Direct, not sandboxed, not App Store | Global hotkey and synthetic paste do not work sandboxed |
| Language | Swift 6.2 tools, strict concurrency, SwiftUI | Current toolchain |
| Build | SwiftPM package + `scripts/bundle.sh` wrapping the binary in `Pladder.app` | No Xcode project to maintain; `Package.swift` opens in Xcode |
| Engine | FluidAudio, Parakeet TDT 0.6B v3, one engine only | Fastest Swift-native option, runs on the Neural Engine. The recording is transcribed in windows while the key is held, so only the last window and the merge are left at release |
| FluidAudio | A fork, branch `incremental-chunks`, pinned in `Package.resolved` | Adds `IncrementalChunkProcessor`: the same windows the batch path uses, run as the audio arrives. Offered upstream; goes back to the release line when it lands |
| Hotkey | Hold Option+Space by default, either Option; any key or chord can be recorded | A CGEvent tap (Accessibility, no Input Monitoring) matches the chord and swallows its regular key so it never reaches the target app. Sides are ignored in a chord with a regular key and kept for a modifier-only chord, so the tap and Carbon agree |
| Interrupted press | A non-chord key within 1 s of the chord press cancels the recording without transcribing | Anyone who records a lone Command key shares it with Cmd+C, Cmd+V and Cmd+Tab; the overlay waits 150 ms before showing so those never flash it. Option+Space shares no modifier with them |
| Secure Event Input | `IsSecureEventInputEnabled()` polled with the grant; sustained 3 s and a chord Carbon can register → Carbon monitor until it clears | A password field or Terminal's Secure Keyboard Entry stops taps receiving key events; modifier-only chords are unaffected and stay on the tap |
| Without Accessibility | Carbon `RegisterEventHotKey` plus clipboard-only output | A standard account cannot grant Accessibility without an admin. Carbon needs no permission but wants exactly one regular key and collapses left and right, so modifier-only chords are refused in the recorder; the transcript is left on the clipboard and the overlay says "press ⌘V". A stored chord Carbon cannot register, a lone Right Command say, is stood in for by the default Option+Space and the menu names it; the stored chord returns with the grant. `CopySymbolicHotKeys` only feeds the warning that an enabled macOS shortcut owns the recorded chord. `AppModel` polls the grant every two seconds and swaps the monitor in both directions |
| Send key | Press Right Option (configurable) while the hotkey is held and Return is posted 50 ms after Cmd+V | Sends a chat message or runs a command without a second trip to the keyboard; the Return is posted from a detached task so it stays off the release-to-paste path |
| Polish hotkey | "Dictate and polish": a second recordable chord, off by default. A dictation started with it runs the usual pipeline, then Apple's on-device model (FoundationModels, `PladderRefine`) with a fixed cleanup prompt, then pastes | Self-corrections, spoken punctuation, number words and lists are beyond the deterministic processors, and the model runs on device with nothing to download. It costs one to three seconds, so it never touches the normal hotkey's path: the branch is one Bool read; the session is created and prewarmed at key-down; transcripts under four words skip it; anything the model cannot do (Apple Intelligence off, refusal, the 8 s timeout) pastes the text as dictated. Logged as its own `polished release-to-paste` line |
| Learned corrections | After a paste the field is watched through Accessibility for up to 60 s; a word the user corrects that passes a token diff, a phonetic gate (Soundex or edit distance ≤ 2) and a yes/no review by the on-device model becomes one menu line, "Learned “x” → “y”? Add / Dismiss" | Nothing runs before Cmd+V is posted: the hook is in `AppModel.handle(.inserted)`, the watcher lives on its own thread and reads only the pasted range plus a margin, the review runs on a detached task. Present only with Accessibility and Apple Intelligence, absent otherwise, no setting, no change to the menu bar glyph. Dismissed pairs go to `dismissed-corrections.json`, not settings, so a bug there can never cost the dictionary. Pure case changes are never proposed. Terminals and TUIs expose a screen buffer, not a field, so nothing is learned there |
| Output | Clipboard + simulated Cmd+V; the old clipboard is restored off the critical path | Universal, fast |
| Post-processing | Filler remover, dictionary replacer, fuzzy custom-word corrector, whitespace normaliser, in that order | No latency, no network. An earlier Apple Intelligence step was removed from this path unmeasured; the model is back behind the polish hotkey only |
| Mute while dictating | Off by default; `kAudioDevicePropertyMute` on the default output device 200 ms into a recording, restored off the release path | Music or a call otherwise goes into the microphone. The delay means a tap-and-release never toggles anything; a device the user had already muted is left alone, and the device that was muted is the one unmuted even if the default changed meanwhile |
| UI language | Follows the macOS system language; no setting | String Catalogs (`Localizable.xcstrings` in the app, `KeyNames.xcstrings` in `PladderSystem`) are compiled by `swift build`; `bundle.sh` merges their `.lproj` folders into `Pladder.app/Contents/Resources`, so `Bundle.main` serves them and no code names a bundle. `swift run` shows English. Core and Engines emit enum cases; the app turns them into text. German first; more languages are catalog contributions |
| Recording cap | 120 s | Keeps the microphone from staying on when a key-up is lost |
| Benchmark | A script run by hand, not a test | A benchmark that fails on noise gets ignored |

## Pluggability rules

- `PladderCore` imports Foundation only. It never imports FluidAudio, AVFoundation or AppKit, so tests compile fast and engines are truly swappable.
- Adding an engine: implement `TranscriptionEngine` in its own file under `PladderEngines`, register it in the `EngineRegistry` built in `AppModel`. One file plus one registry line; the settings picker reads the registry. The engine lifecycle — building, loading, status polling and swapping — lives in `EngineLoader`.
- Adding a processor: implement `TextProcessor` in its own file, append a factory to `processorFactories` in `AppModel`. The pipeline is rebuilt when settings change, never per dictation. A processor sits on the critical path, so the benchmark rule applies.
- Adding a prompt: build an `OnDeviceLanguageModel(instructions:)` in `PladderRefine` and call `respond(to:)` or `respond(to:generating:)`; availability, prewarm, timeout and the drain of an abandoned call come with it. The coordinator only ever sees `TranscriptRefiner`.
- The correction learner's two seams are protocols in `PladderCore`, `PastedTextObserver` and `CorrectionReviewer`, with fakes in the tests; the Accessibility and Foundation Models implementations live in `PladderSystem` (`AXPasteObserver`) and `PladderRefine` (`FoundationModelsCorrectionReviewer`).
- Adding a language: add a `<code>` localization to both catalogs; nothing else. Adding a *string*: the key is the exact English text, and `PladderCore` never holds one — it emits an enum case and `Sources/Pladder/StatusText.swift` words it.
- Engine and capture are actors. The coordinator is `@MainActor` because it drives UI. It owns the state machine and nothing else; every dependency is injected, so tests run it with in-memory fakes.

## Risks

- **Audio format.** The microphone delivers 48 kHz; the engine wants 16 kHz mono Float32. Conversion is isolated in `AudioResampler` and unit tested against synthesised buffers.
- **First launch.** About 700 MB of CoreML models download from Hugging Face and compile on first load. The menu shows progress and the hotkey is disabled until the engine is ready.
- **Cold latency.** The engine loads at launch and stays resident. The audio engine is prepared at launch and runs only while the key is held, so the system microphone indicator is off when idle. A cold encoder pass costs about 110 ms more than a warm one, which is more than every other stage together, so the coordinator warms the Neural Engine every two seconds while the key is held. A release that lands inside a warm pass waits for it: the signature is `engine` well above `engine-time`.
- **Long recordings.** FluidAudio's encoder window is 15 s. Longer audio is split into windows and stitched, and seams can drop or duplicate words. Those windows now run while the key is held rather than at release, so the wait is flat with length, but the seam risk is unchanged: it is the same layout and the same merge. The paced benchmark guards it by requiring the text to be byte-identical to transcribing the whole recording at once, and the 30 s to 10 min fixtures watch the word error rate.
- **Polish latency and quality.** The model takes about 1.5 to 2 seconds warm on an M1 for a typical dictation and is capped at eight; past the cap the text is pasted as dictated. A small model can still rewrite rather than clean; the guided `cleanedText` field, greedy sampling, inline examples and naming the transcript's language keep that rare, and `pladder-cli polish` is where prompt changes are judged.
- **Clipboard clobbering.** Output saves the pasteboard, pastes, and restores it after a short delay.
- **Permissions.** Accessibility and Microphone grants are keyed to the code signature. `bundle.sh` signs with an Apple Development or Developer ID certificate when one is in the keychain; an ad-hoc signature changes on every build and resets both grants.
- **Lost key-up.** When the 120 s watchdog fires, the coordinator transcribes and pastes as if the user had released. Discarding is probably the right behaviour; tracked separately.

## Working on this Mac while Pladder is in use

The developer dictates with a running Pladder all day, often into Claude sessions, and several worktrees may each have their own `dist/Pladder.app`.

- Never `pkill -x Pladder` or `killall Pladder`: that also kills the copy in use, mid-recording, and the text is lost. Stop only the copy you launched: `pkill -f "$PWD/dist/Pladder.app"`.
- Do not post synthetic hotkey events unless the user has asked for a live UI test. Every running copy reacts to them, so they start, cut short, or paste the user's recordings.
- Do not edit `~/Library/Application Support/Pladder/settings.json`; it is the live configuration.
