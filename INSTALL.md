# Installing Pladder

## Requirements

- macOS 26 or later.
- An Apple Silicon Mac (M1 or newer). The speech model runs on the Neural Engine.
- Xcode 26 (Swift 6.2 or later) to build. There is no binary release yet.
- About 700 MB of disk for the speech model, downloaded once.

## Build and install

```sh
git clone https://github.com/dinooo13/speakup.git
cd speakup
./scripts/bundle.sh --install --run
```

This compiles a release build, wraps it into `Pladder.app`, signs it, copies it to `/Applications` and launches it. Pladder lives in the menu bar; there is no Dock icon.

## First launch

1. **Grant Microphone** when macOS asks. That is what records your voice.
2. **Grant Accessibility** when prompted. System Settings opens on the Accessibility list; switch Pladder on. That is what lets Pladder see the push-to-talk key in other apps and paste the result. It does not need Input Monitoring.
3. **Wait for the model.** The first run downloads the Parakeet TDT v3 CoreML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models` and compiles them. The menu bar icon shows progress, and the push-to-talk key is disabled until the engine is ready. This happens once; later launches load in well under a second.

Then click into any text field, hold **Right Command**, say something, and let go.

If a permission was missed, the menu bar menu offers **Grant Accessibility…** and **Grant Microphone…**, and the General tab of Settings shows both with a one-click fix.

## Updating

Pull and run the same command again:

```sh
git pull
./scripts/bundle.sh --install --run
```

The install step quits the running copy and replaces it. Because the app is signed with your development certificate, macOS keeps the Microphone and Accessibility grants across updates. See [Signing](#signing) if it asks again.

## Uninstalling

1. Quit Pladder from the menu bar.
2. Delete `/Applications/Pladder.app`.
3. Optionally delete the settings in `~/Library/Application Support/Pladder` and the models in `~/Library/Application Support/FluidAudio`.
4. Optionally remove Pladder from Privacy & Security > Accessibility and > Microphone in System Settings.

## Building for development

The project is a Swift package with no Xcode project file; open `Package.swift` in Xcode if you prefer an IDE.

```sh
swift build                      # debug build of everything
swift test                       # unit tests, run in well under a second
./scripts/bundle.sh              # release build → dist/Pladder.app, signed
./scripts/bundle.sh --run        # …and launch it
./scripts/bundle.sh --install    # …and copy to /Applications
swift run pladder-cli audio.wav  # transcribe a file from the terminal
```

### Signing

macOS ties the Microphone and Accessibility grants to the app's code signature. The bundle script looks for an **Apple Development** or **Developer ID Application** certificate in your keychain and signs with the first one it finds, which gives the app a stable identity across rebuilds. Without a certificate it falls back to an ad-hoc signature, which changes on every build and makes macOS ask for both permissions again.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
CODESIGN_IDENTITY=- ./scripts/bundle.sh     # force ad-hoc
```

A free Apple ID is enough for an Apple Development certificate: sign in to Xcode under Settings > Accounts and click Manage Certificates.

### Command-line transcriber

`pladder-cli` loads the same engine and prints the transcript for any audio file. It is the quickest way to check the model without the GUI, and prints timing so you can see the real-time factor on your machine.

```sh
swift run -c release pladder-cli recording.wav
```

`pladder-cli bench <dir>` runs the benchmark over synthetic fixtures. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the procedure and the M1 baseline.

### Icon and screenshots

The app icon is rendered from code so it can be regenerated at any size, and the README pictures are rendered from the app's own views:

```sh
swift scripts/make-icon.swift Assets     # writes Assets/icon_1024.png
./scripts/make-screenshots.sh            # writes docs/images/*.png
```

`Assets/AppIcon.icns` is built from the icon with `iconutil` and copied into the bundle. The screenshot script needs Screen Recording for the terminal that runs it, and shows a few windows for a second or two.

## Troubleshooting

**The key does nothing.**
Check the menu bar menu. If it says the model is loading or downloading, wait. If it offers **Grant Accessibility…**, the grant is missing; it is keyed to the code signature, so a rebuild with an ad-hoc signature resets it.

**macOS asks for permissions after every build.**
The app was signed ad-hoc. Install a development certificate so the signature stays stable; see [Signing](#signing).

**The model download failed.**
The menu offers **Retry Model Download**. The files come from Hugging Face; a proxy or firewall that blocks it will stop the download. Once the models are in `~/Library/Application Support/FluidAudio/Models`, no network is needed again.

**Text is pasted into the wrong app.**
Pladder pastes into whatever has keyboard focus when the key is released. Click into the target field before holding the key.

**A plain key stops working in other apps.**
A push-to-talk key without a modifier is swallowed system wide while Pladder runs, so a bare letter or Space would become untypeable. Settings warns about this; use a modifier or a chord.

**Where are the settings?**
`~/Library/Application Support/Pladder/settings.json`, plain JSON. The dictionary can also be imported and exported from the Dictionary tab.

**How do I see the release-to-paste time?**
Every dictation logs one line:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```
