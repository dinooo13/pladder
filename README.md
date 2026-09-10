<p align="center">
  <img src="Assets/icon_1024.png" width="160" alt="SpeakUp icon">
</p>

<h1 align="center">SpeakUp</h1>

<p align="center">
  Push-to-talk dictation for macOS. Hold a key, speak, let go. The words land where your cursor is.<br>
  Fast, private, and entirely on your Mac.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#building-from-source">Build</a> ·
  <a href="#customising">Customise</a>
</p>

---

## Why SpeakUp

- **Hold to talk.** One key, no toggles, no windows to click. Hold Right Command, or any key or combination you choose, speak, release. Works in every app that takes text.
- **Fast.** NVIDIA's Parakeet TDT v3 runs on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). A ten second sentence transcribes in well under half a second. The model stays loaded, so the first word is as quick as the last.
- **Private.** Audio never leaves your Mac. There is no account, no cloud, no telemetry. The microphone is only open while the key is held, and macOS shows the orange indicator only then.
- **Accurate with your words.** A dictionary fixes the names and jargon speech models get wrong. "clode code" becomes "Claude Code" every time.
- **Native.** A menu bar app with a Liquid Glass status pill and a standard settings window. It looks and behaves like it shipped with the system.
- **Multilingual.** Parakeet v3 handles 25 European languages and switches automatically. Dictate in English, German or Spanish in the same session.


## Install

**Requirements:** macOS 26 or later on Apple Silicon.

There is no binary release yet. Build it yourself in about a minute:

```sh
git clone https://github.com/dinooo13/speakup.git
cd speakup
./scripts/bundle.sh --install --run
```

That compiles a release build, wraps it into `SpeakUp.app`, signs it, copies it to `/Applications`, and launches it. SpeakUp lives in the menu bar; there is no Dock icon.

On first launch:

1. **Grant Microphone** when macOS asks. That is what records your voice.
2. **Grant Accessibility** in System Settings when prompted. That is what lets SpeakUp see the push-to-talk key in other apps and paste the result.
3. Wait for the model. The first run downloads about 700 MB of CoreML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models`. The menu bar shows progress. This happens once.

Then click into any text field, hold **Right Command**, say something, and let go.

## How it works

```
hold key ──► microphone opens, pill shows your level
release  ──► Parakeet transcribes on the Neural Engine
         ──► your dictionary fixes names and terms
         ──► text is pasted at the cursor, clipboard restored
```

The pill at the bottom of the screen tells you what is happening: a red dot and live level bars while recording, a spinner while transcribing, a tick when the text is in. It never takes focus from the app you are typing into.

## Customising

Open **Settings…** from the menu bar icon.

| Tab | What you can change |
|---|---|
| **General** | Engine, push-to-talk key (any key or combination, recorded by pressing it; Right Command by default), trailing space, sounds, launch at login. Shows permission status with a one-click fix. |
| **Dictionary** | Replacement rules: what the model hears, what you want written, and whether case must match. Whole-word matching, longer phrases win, capitalisation carries over at the start of a sentence. Import and export as JSON. A test field shows the effect of your rules live. |
| **Processing** | Toggle each post-processing step. Dictionary and whitespace tidying are on by default. **Apple Intelligence cleanup** uses the on-device Foundation Models framework to fix punctuation and capitalisation; it adds about a second and is off by default. |


Settings are stored as plain JSON in `~/Library/Application Support/SpeakUp/settings.json`.

## Building from source

Xcode 26 (Swift 6.2 or later) is the only dependency. The project is a Swift package with no Xcode project file; open `Package.swift` in Xcode if you prefer an IDE.

```sh
swift build                      # debug build of everything
swift test                       # 34 unit tests, run in well under a second
./scripts/bundle.sh              # release build → dist/SpeakUp.app, signed
./scripts/bundle.sh --run        # …and launch it
./scripts/bundle.sh --install    # …and copy to /Applications
swift run speakup-cli audio.wav  # transcribe a file from the terminal
```

### Signing

macOS ties the Microphone and Accessibility grants to the app's code signature. The bundle script looks for an **Apple Development** or **Developer ID Application** certificate in your keychain and signs with the first one it finds, which gives the app a stable identity across rebuilds. Without a certificate it falls back to an ad-hoc signature, which changes on every build and makes macOS ask for both permissions again.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
CODESIGN_IDENTITY=- ./scripts/bundle.sh     # force ad-hoc
```

### Icon

The app icon is rendered from code so it can be regenerated at any size:

```sh
swift scripts/make-icon.swift Assets     # writes Assets/icon_1024.png
```

`Assets/AppIcon.icns` is built from it with `iconutil` and copied into the bundle.

### Command-line transcriber

`speakup-cli` loads the same engine and prints the transcript for any audio file. It is the quickest way to check the model without the GUI, and prints timing so you can see the real-time factor on your machine.

## Privacy

SpeakUp makes exactly one kind of network request: downloading the speech model from Hugging Face on first launch. After that it works offline. Nothing you say is stored; the transcript exists only long enough to be pasted, and your previous clipboard contents are restored afterwards.

## License

MIT. See [LICENSE](LICENSE).

Parakeet TDT is by NVIDIA (CC-BY-4.0). FluidAudio is by FluidInference (Apache-2.0).
