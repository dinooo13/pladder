<p align="center">
  <img src="Assets/icon_1024.png" width="160" alt="SpeakUp icon">
</p>

<h1 align="center">SpeakUp</h1>
<p align="center">
  Push-to-talk dictation for your agents. Hold a key, speak, let go. Transcription pastes almost instant.
  <br>
  <br>
  Insanely fast · 100% private · No data leaves your Mac
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#building-from-source">Build</a> ·
</p>

---

## Why SpeakUp

- **Push to talk.** One action, configurable by hotkey. Right Command is the default. Hold, speak, release. Works in every app that takes text.
- **Fast.** NVIDIA's Parakeet TDT v3 runs on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). A 30-second sentence transcribes in well under half a second. The model stays loaded, so the first word is as quick as the last.
- **Private.** Audio never leaves your Mac. There is no account, no cloud, no telemetry. The microphone is only open while the key is held.
- **Accurate with your words.** A dictionary fixes the names and jargon speech models get wrong. "clode code" becomes "Claude Code" every time.
- **Native.** A menu bar app with a recording overlay and a settings window. It looks and behaves like it shipped with the system.
- **Multilingual.** Parakeet v3 handles 25 European languages and switches automatically. Dictate in English, German or Spanish in the same sentence.


## Install

**Requirements:** macOS 26 or later on Apple Silicon.

There is no packaged release yet. Build it yourself like so:

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

### Signing

macOS ties the Microphone and Accessibility grants to the app's code signature. The bundle script looks for an **Apple Development** or **Developer ID Application** certificate in your keychain and signs with the first one it finds, which gives the app a stable identity across rebuilds. Without a certificate it falls back to an ad-hoc signature, which changes on every build and makes macOS ask for both permissions again.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
CODESIGN_IDENTITY=- ./scripts/bundle.sh     # force ad-hoc
```

### Command-line transcriber

`speakup-cli` loads the same engine and prints the transcript for any audio file. It is the quickest way to check the model without the GUI, and prints timing so you can see the real-time factor on your machine.

`speakup-cli bench <dir>` runs the benchmark over synthetic fixtures. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the procedure and the M1 baseline.

## Privacy

SpeakUp makes exactly one kind of network request: downloading the speech model from Hugging Face on first launch. After that it works offline. Nothing you say is stored; the transcript exists only long enough to be pasted, and your previous clipboard contents are restored afterwards.

## License

MIT. See [LICENSE](LICENSE).

Parakeet TDT is by NVIDIA (CC-BY-4.0). FluidAudio is by FluidInference (Apache-2.0).
