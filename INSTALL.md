# Installing Pladder

## Requirements

- macOS 26 or later.
- An Apple Silicon Mac (M1 or newer). The speech model runs on the Neural Engine.
- Xcode 26 (Swift 6.2 or later), only to build from source.
- About 600 MB of disk for the speech model, downloaded once.

## Download

Get `Pladder.dmg` from the [latest release](https://github.com/dinooo13/pladder/releases/latest), open it and drag Pladder to Applications.

## Build and install

```sh
git clone https://github.com/dinooo13/pladder.git
cd pladder
./scripts/bundle.sh --install --run
```

This compiles a release build, wraps it into `Pladder.app`, signs it, copies it to `/Applications` and launches it. Pladder lives in the menu bar; there is no Dock icon.

## First launch

1. **Grant Microphone** when macOS asks. That is what records your voice.
2. **Grant Accessibility** when prompted. System Settings opens on the Accessibility list; switch Pladder on. That is what lets Pladder see the push-to-talk key in other apps, paste the result, and notice when you correct a word it got wrong. It does not need Input Monitoring.

   On a standard (non-administrator) account, ticking that box asks for an administrator password, so ask an admin to do it once — the grant is keyed to the app's code signature and survives updates. Without it Pladder still works in a reduced form: Option+Space works the same, any combination with a regular key can be recorded in Settings (a modifier-only key such as Right Command needs Accessibility, and Option+Space stands in for it until then), and the transcript is left on the clipboard for you to paste with ⌘V. Managed Macs can pre-approve Accessibility for Pladder with an MDM Privacy Preferences Policy Control (PPPC) profile, which needs no prompt at all.

   Apple Intelligence, if it is on, powers learned corrections and, if you pick it, the experimental polish; nothing else needs it.
3. **Wait for the model.** The first run downloads the Parakeet Ultra CoreML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models` and compiles them. The menu bar icon shows progress, and the push-to-talk key is disabled until the engine is ready. This happens once; later launches load in well under a second.

Then click into any text field, hold **Option+Space**, say something, and let go.

If a permission was missed, the menu bar menu offers **Grant Accessibility…** and **Grant Microphone…**, and the General tab of Settings shows both with a one-click fix.

## Updating

A downloaded copy: quit Pladder, download the new DMG and drag it to Applications again, replacing the old one. Pladder does not check for updates itself, because that would be a network call; watch the [releases](https://github.com/dinooo13/pladder/releases) instead.

A copy built from source: pull and run the same command again:

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

macOS ties the Microphone and Accessibility grants to the app's code signature. The bundle script signs with a **Developer ID Application** certificate if your keychain has one, and otherwise with an **Apple Development** certificate, which gives the app a stable identity across rebuilds. Without either it falls back to an ad-hoc signature, which changes on every build and makes macOS ask for both permissions again.

The two certificates differ in what a grant remembers. An Apple Development signature is matched on the name of your certificate; a Developer ID signature on the team. So a copy signed with Developer ID, a self-built one or the released DMG, shares its grants with every other Developer ID copy of the same team, and a move between the two kinds, such as from an Apple Development build to the DMG, makes macOS ask for Microphone and Accessibility once more. Developer ID needs the paid Apple Developer Program; Apple Development does not.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
CODESIGN_IDENTITY=- ./scripts/bundle.sh     # force ad-hoc
```

A free Apple ID is enough for an Apple Development certificate: sign in to Xcode under Settings > Accounts and click Manage Certificates.

### Releasing

A release comes from the **Release** workflow (`.github/workflows/release.yml`): Actions > Release > Run workflow, on `main`, with the version, `0.1.1` say. Preview its notes first; they are exactly what this prints, with the last tag in place of `v0.1.0`:

```sh
./scripts/changelog.sh v0.1.0 HEAD
```

Before anyone is asked to approve, a Linux job refuses a ref other than `main`, a version that is not `major.minor.patch`, one whose tag exists or that is not newer than the last tag, and a release in which nothing the build reads (the paths `ci.yml` builds for) changed since the last tag, unless **force** is ticked. The release job then waits for a reviewer of the `release` environment. Once approved, it tags the commit `v<version>`, builds and runs the tests as CI does, imports the certificate into a throwaway keychain, runs `scripts/release.sh`, checks that the build number is the commit count, uploads the DMG as a workflow artifact, and publishes the release "Pladder <version>" with `Pladder.dmg`, its `.sha256` and the notes from `scripts/changelog.sh`. Every release names its DMG `Pladder.dmg`, so `releases/latest/download/Pladder.dmg` always resolves; the version is in the tag and the title. Tick **draft** to check a release before it is public. The keychain and the key files are deleted as soon as `release.sh` is done, before the upload and the publish, and also when a step failed. The tag comes first because GitHub lets the workflow's token tag a commit only while its `.github/workflows` matches a branch tip: a push to `main` that changes a workflow during the run would otherwise fail it at the very end. If main's workflows changed between the dispatch and the approval, the job stops at once; run it again. A run that fails or is cancelled before the release exists deletes its tag, so it can simply be run again.

The changelog groups the commit subjects since the last tag by their `Area:` prefix, folds the internal areas (Tests, CI, Bench, Docs, Scripts) into an Internals group at the end, and links the pull request a subject names, `(#93)`, and the issues a body `Closes` or `Refs`. Merge and `fixup!` commits are left out.

The signing secrets live in the `release` environment, so only a run a reviewer approved can read them, and only from `main`:

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, as a base64 `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | The password the `.p12` was exported with |
| `NOTARY_API_KEY` | An App Store Connect API key with the Developer role, the contents of its `AuthKey_<key ID>.p8` |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER` | The issuer ID shown above the keys in App Store Connect |

The API key, rather than an Apple ID and an app-specific password, because it can do no more than its role allows and can be revoked on its own. If a secret leaks, revoke the key in App Store Connect and the certificate in the developer portal.

A release can still be built by hand, on a Mac that has the Developer ID Application certificate in its login keychain and a notarytool profile, stored once:

```sh
xcrun notarytool store-credentials pladder-notary --apple-id <Apple ID> --team-id <team ID>
```

It asks for an app-specific password from [account.apple.com](https://account.apple.com) and keeps it in the keychain. Instead of the profile, `NOTARY_KEY` (the path of the `.p8`), `NOTARY_KEY_ID` and `NOTARY_ISSUER` make the script sign in with the API key, as the workflow does. Then, from a clean, full clone of the commit to release:

```sh
./scripts/release.sh 0.1.1
```

The script builds the app with the version and the commit count as its build number, signs it with the hardened runtime and a secure timestamp, notarises and staples the app, packs it with an Applications link into `dist/release/Pladder.dmg`, signs, notarises and staples the DMG, checks both with `spctl` and `stapler validate`, and writes the SHA-256 beside it. It publishes nothing. Tag and publish by hand:

```sh
git tag -a v0.1.1 -m "Pladder 0.1.1" && git push origin v0.1.1
./scripts/changelog.sh v0.1.0 v0.1.1 > notes.md
gh release create v0.1.1 dist/release/Pladder.dmg dist/release/Pladder.dmg.sha256 --title "Pladder 0.1.1" --notes-file notes.md
```

### Command-line transcriber

`pladder-cli` loads the same engine and prints the transcript for any audio file, and nothing else, so a script can read it. It is the quickest way to check the model without the GUI. `--verbose` adds timing, so you can see the real-time factor on your machine, and `--process` runs the app's processors over the text with your dictionary.

```sh
swift run -c release pladder-cli recording.wav
swift run -c release pladder-cli recording.wav --process --verbose
```

It reads WAV, M4A, MP3, FLAC, CAF and Ogg Opus. To use it as the speech-to-text of another program, see [docs/HERMES.md](docs/HERMES.md).

`pladder-cli bench <dir>` runs the benchmark over synthetic fixtures. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the procedure and the M1 baseline.

### Icon and screenshots

The mark is drawn from code, so every picture of it comes from one geometry, and the README pictures are rendered from the app's own views:

```sh
swift scripts/make-icon.swift --font Outfit.ttf   # the icon's layers, the logos, the favicon, the social preview
./scripts/make-screenshots.sh                     # writes docs/images/styles-*.png
```

The app icon is `Assets/AppIcon.icon`, an Icon Composer document; `bundle.sh` compiles it with `actool`, which comes with Xcode, into the light, dark, tinted and clear appearances. `make-icon.swift` writes its layers and colours, and renders `Assets/icon_1024.png` and `site/apple-touch-icon.png` with Icon Composer's `ictool`, so it needs Xcode too. The wordmark is outlined from [Outfit](https://github.com/google/fonts/tree/main/ofl/outfit) SemiBold (SIL Open Font License), `ofl/outfit/Outfit[wght].ttf`; without `--font` the script leaves the wordmark, the logos and the social preview as they are. The screenshot script needs Screen Recording for the terminal that runs it, and shows a few windows for a second or two.

## Troubleshooting

**The key does nothing.**
Check the menu bar menu. If it says the model is loading or downloading, wait. If it offers **Grant Accessibility…**, the grant is missing; it is keyed to the code signature, so a rebuild with an ad-hoc signature resets it.

**macOS asks for permissions after every build.**
The app was signed ad-hoc. Install a development certificate so the signature stays stable; see [Signing](#signing). It also asks once after a move between an Apple Development and a Developer ID signature, such as from a self-built copy to the downloaded one.

**The model download failed.**
The menu offers **Retry Model Download**. The files come from Hugging Face; a proxy or firewall that blocks it will stop the download. Once the models are in `~/Library/Application Support/FluidAudio/Models`, no network is needed again.

**Text is pasted into the wrong app.**
Pladder pastes into whatever has keyboard focus when the key is released. Click into the target field before holding the key.

**A plain key stops working in other apps.**
A push-to-talk key without a modifier is swallowed system wide while Pladder runs, so a bare letter or Space would become untypeable. Settings warns about this; use a modifier or a chord.

**Where are the settings?**
`~/Library/Application Support/Pladder/settings.json`, plain JSON. The dictionary can also be imported and exported from the Dictionary tab. Corrections you answered Dismiss to are kept beside it in `dismissed-corrections.json`; delete that file to be asked about them again.

**A word I corrected is never proposed.**
Proposals need Accessibility and Apple Intelligence, and appear in the menu bar menu up to a minute after the dictation, or as soon as you click away from the field. Only a word or two changed into something that sounds alike is proposed; a change of case, a rewording or an edit next to the dictation is not. Terminals, and apps such as Claude Code that run in one, show a screen rather than a text field, so nothing is learned there.

**How do I see the release-to-paste time?**
Every dictation logs one line:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```
