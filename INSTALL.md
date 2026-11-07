# Installing Pladder

## Requirements

- macOS 26 or later.
- An Apple Silicon Mac (M1 or newer). The speech model runs on the Neural Engine.
- Xcode 26 (Swift 6.2 or later), only to build from source.
- About 600 MB of disk for the speech model, downloaded once.

## Download

Get `Pladder.dmg` from the [latest release](https://github.com/dinooo13/pladder/releases/latest), open it and drag Pladder to Applications.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask dinooo13/tap/pladder
```

It is the same notarised DMG, so macOS asks only the usual question at the first launch.

## Build and install

```sh
git clone https://github.com/dinooo13/pladder.git
cd pladder
./scripts/bundle.sh --install --run
```

This compiles a release build, wraps it into `Pladder.app`, signs it, copies it to `/Applications` and launches it. Pladder lives in the menu bar; there is no Dock icon.

## First launch

Settings opens by itself the first time, with what Pladder still needs at the top and the speech model's download below it.

1. **Allow the microphone.** Click **Allow…** and accept the macOS prompt. That is what records your voice.
2. **Allow Accessibility.** Click **Allow…**, then **Open System Settings** in the alert; System Settings opens on the Accessibility list; switch Pladder on. That is what lets Pladder see the push-to-talk key in other apps, paste the result, and notice when you correct a word it got wrong. It does not need Input Monitoring.

   On a standard (non-administrator) account, ticking that box asks for an administrator password, so ask an admin to do it once — the grant is keyed to the app's code signature and survives updates. Without it Pladder still works in a reduced form: Option+Space works the same, any combination with a regular key can be recorded in Settings (a modifier-only key such as Right Command needs Accessibility, and Option+Space stands in for it until then), and the transcript is left on the clipboard for you to paste with ⌘V. Managed Macs can pre-approve Accessibility for Pladder with an MDM Privacy Preferences Policy Control (PPPC) profile, which needs no prompt at all, or keep Pladder off it with a profile of their own; what an organisation can fix is in [docs/MANAGED.md](docs/MANAGED.md).

   Apple Intelligence, if it is on, powers learned corrections and, if you pick it, the experimental polish; nothing else needs it.
3. **Wait for the model.** The first run downloads the Parakeet Ultra CoreML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models` and compiles them. Settings and the menu show the progress, the menu bar icon is dimmed meanwhile, and the push-to-talk key is disabled until the model is ready. This happens once; later launches load in well under a second.

Then click into any text field, hold **Option+Space**, say something, and let go.

If a permission was missed, the menu bar menu offers **Allow Accessibility Access…** and **Allow Microphone Access…** right under its status line, and the General tab of Settings lists what is missing at the top.

## Updating

A downloaded copy updates itself. Choose **Check for Updates…** in the menu bar menu: if a newer release is out, Pladder shows what changed and offers to install it, downloads the DMG, checks its two signatures (Apple's Developer ID and Pladder's own EdDSA key), and replaces itself when you click **Install and Relaunch**. A dictation still on its way out is pasted first, and the clipboard and the speakers are given back, as on any quit. Microphone and Accessibility stay granted.

To have Pladder look by itself, turn on **Check for updates automatically** in Settings > General. It is off until you do. Then Pladder asks GitHub once a day for `appcast.xml`, a small file that lists the newest release, and when there is one, the menu gets a line, **Pladder 0.3.0 is available — Install…**; no window opens until you click it. A check sends nothing about you, your Mac or your dictations. With the setting off, Pladder makes no request until you choose Check for Updates….

Pladder updates itself wherever it is, as long as you can write there. A copy opened straight from the DMG, or from Downloads before macOS has moved it out of quarantine, says to move it to Applications first.

**Copies of 0.1.x have no updater.** Replace one by hand once: quit Pladder, download the [latest DMG](https://github.com/dinooo13/pladder/releases/latest) and drag Pladder to Applications, replacing the old copy. From then on it updates itself.

A copy installed with Homebrew updates with the rest of your casks: `brew upgrade` quits Pladder, replaces it and opens it again. Check for Updates… works there too; after it has updated a copy, the next `brew upgrade` installs the same version once more, which costs a download and nothing else.

```sh
brew upgrade
```

A copy built from source: pull and run the same command again:

```sh
git pull
./scripts/bundle.sh --install --run
```

The install step quits the running copy and replaces it. Because the app is signed with your development certificate, macOS keeps the Microphone and Accessibility grants across updates. See [Signing](#signing) if it asks again. A copy built from source gets the commit count as its build number, and Check for Updates… offers it a release only when the release's build number is higher, that is when the release has commits the copy does not.

## Uninstalling

A copy installed with Homebrew:

```sh
brew uninstall --cask pladder          # the app only
brew uninstall --cask --zap pladder    # also the settings, the dictionary and the speech model
```

Otherwise, by hand:

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

Before anyone is asked to approve, a Linux job refuses a ref other than `main`, a version that is not `major.minor.patch`, one whose tag exists or that is not newer than the last tag, and a release in which nothing the build reads (the paths `ci.yml` builds for) changed since the last tag, unless **force** is ticked. The release job then waits for a reviewer of the `release` environment. Once approved, it tags the commit `v<version>`, builds and runs the tests as CI does, imports the certificate into a throwaway keychain, runs `scripts/release.sh`, checks that the build number is the commit count, signs the DMG with the update key and writes `appcast.xml` with `scripts/appcast.sh`, uploads the DMG as a workflow artifact, and publishes the release "Pladder <version>" with `Pladder.dmg`, its `.sha256`, `appcast.xml` and the notes from `scripts/changelog.sh`, then bumps the [Homebrew](#homebrew) cask. Every release names its DMG `Pladder.dmg` and its feed `appcast.xml`, so `releases/latest/download/Pladder.dmg` always resolves and every copy's feed, `releases/latest/download/appcast.xml`, is always the newest release's; the version is in the tag and the title. Tick **draft** to check a release before it is public. The keychain and the key files are deleted as soon as `release.sh` is done, before the upload and the publish, and also when a step failed. The tag comes first because GitHub lets the workflow's token tag a commit only while its `.github/workflows` matches a branch tip: a push to `main` that changes a workflow during the run would otherwise fail it at the very end. If main's workflows changed between the dispatch and the approval, the job stops at once; run it again. A run that fails or is cancelled before the release exists deletes its tag, so it can simply be run again.

The changelog groups the commit subjects since the last tag by their `Area:` prefix, folds the internal areas (Tests, CI, Bench, Docs, Scripts) into an Internals group at the end, and links the pull request a subject names, `(#93)`, and the issues a body `Closes` or `Refs`. Merge and `fixup!` commits are left out.

The signing secrets live in the `release` environment, so only a run a reviewer approved can read them, and only from `main`:

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, as a base64 `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | The password the `.p12` was exported with |
| `NOTARY_API_KEY` | An App Store Connect API key with the Developer role, the contents of its `AuthKey_<key ID>.p8` |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER` | The issuer ID shown above the keys in App Store Connect |
| `SPARKLE_ED_PRIVATE_KEY` | The private EdDSA key updates are signed with, as `generate_keys -x` writes it (see [Update signing key](#update-signing-key)) |
| `HOMEBREW_TAP_TOKEN` | A fine-grained token for the tap; see [Homebrew](#homebrew) |

The API key, rather than an Apple ID and an app-specific password, because it can do no more than its role allows and can be revoked on its own. If a secret leaks, revoke the key in App Store Connect and the certificate in the developer portal.

A release can still be built by hand, on a Mac that has the Developer ID Application certificate in its login keychain and a notarytool profile, stored once:

```sh
xcrun notarytool store-credentials pladder-notary --apple-id <Apple ID> --team-id <team ID>
```

It asks for an app-specific password from [account.apple.com](https://account.apple.com) and keeps it in the keychain. The update key must be in the same login keychain, as `generate_keys` leaves it. Instead of the profile, `NOTARY_KEY` (the path of the `.p8`), `NOTARY_KEY_ID` and `NOTARY_ISSUER` make the script sign in with the API key, as the workflow does. Then, from a clean, full clone of the commit to release:

```sh
./scripts/release.sh 0.1.1
```

The script builds the app with the version and the commit count as its build number, signs it with the hardened runtime and a secure timestamp, notarises and staples the app, packs it with an Applications link into `dist/release/Pladder.dmg`, signs, notarises and staples the DMG, checks both with `spctl` and `stapler validate`, and writes the SHA-256 beside it. It publishes nothing. Tag and publish by hand:

```sh
git tag -a v0.1.1 -m "Pladder 0.1.1" && git push origin v0.1.1
./scripts/changelog.sh v0.1.0 v0.1.1 > notes.md
./scripts/appcast.sh dist/Pladder.app dist/release/Pladder.dmg notes.md > dist/release/appcast.xml
gh release create v0.1.1 dist/release/Pladder.dmg dist/release/Pladder.dmg.sha256 dist/release/appcast.xml --title "Pladder 0.1.1" --notes-file notes.md
```

`appcast.sh` signs the DMG with the key from the login keychain (or from `SPARKLE_ED_KEY`, as the workflow passes it), checks the signature against the `SUPublicEDKey` of the app, and prints the feed.

### Update signing key

Every update is signed with one EdDSA key pair. The public half is `SUPublicEDKey` in `Sources/Pladder/Resources/Info.plist`, so every copy carries it; the private half signs each release's DMG. A build with an empty `SUPublicEDKey` has no updater, and `bundle.sh --release` refuses one. The pair is made once, on the Mac, with the `generate_keys` that SwiftPM fetched with Sparkle:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account pladder
```

It keeps the private key in the login keychain and prints the public key; put that into `SUPublicEDKey`. Export the private key, store it as the `release` environment secret `SPARKLE_ED_PRIVATE_KEY`, keep a copy offline, and delete the file:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account pladder -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY --env release < sparkle-private-key.txt
rm sparkle-private-key.txt
```

`appcast.sh` by hand signs with the keychain's `pladder` account. Keep the offline copy somewhere safe: every copy checks the DMG against this one public key before opening it (`SUVerifyUpdateBeforeExtraction`), so with the private key lost no update can reach them, and each would have to be replaced by hand once more. If the key leaks, make a new pair, ship the new public key in a release signed with the old private key, and replace the secret.

### Homebrew

The cask lives in its own repository, [dinooo13/homebrew-tap](https://github.com/dinooo13/homebrew-tap), as `Casks/pladder.rb`, which is what `brew install --cask dinooo13/tap/pladder` reads. Its source is `scripts/pladder.rb` here, with the version and the SHA-256 left out; `scripts/cask.sh` fills them in. Change the cask here, not in the tap: the next release overwrites the tap's copy.

After the publish, the Release workflow writes `Casks/pladder.rb` for the new version and the SHA-256 of its DMG, and commits it to the tap through the GitHub API with `HOMEBREW_TAP_TOKEN`, as "pladder <version>"; the first release with the step, 0.2.0, creates the file. `brew upgrade` picks it up after the next `brew update`, which Homebrew runs by itself. A draft is not bumped, since its DMG is not public yet. A failed bump leaves the run green, since the release is already out; it shows as a failed step. Bump by hand then, or after publishing a draft, from a clone of the tap:

```sh
../pladder/scripts/cask.sh 0.1.3 > Casks/pladder.rb   # reads the SHA-256 from the release
git commit -am "pladder 0.1.3" && git push
```

`HOMEBREW_TAP_TOKEN` is a fine-grained personal access token with access to `dinooo13/homebrew-tap` only, and only the **Contents: Read and write** permission. It is a `release` environment secret, like the signing secrets; when it expires, the bump fails until a new one is stored.

Check a change to the cask with `brew style` and `brew audit --cask --strict --online`, which need it in a tap. A throwaway local tap does it without touching the real one:

```sh
brew tap-new --no-git pladder-check/tap
mkdir -p "$(brew --repo pladder-check/tap)/Casks"
./scripts/cask.sh 0.1.2 > "$(brew --repo pladder-check/tap)/Casks/pladder.rb"
brew style --cask pladder-check/tap/pladder
brew audit --cask --strict --online pladder-check/tap/pladder
brew untap pladder-check/tap
```

`brew audit --new` also asks for the notability the main Homebrew repository wants, which Pladder does not meet yet. The cask does not say `auto_updates true`, although Pladder has an updater: that line makes `brew upgrade` skip the app unless `--greedy`, and Pladder checks for updates by itself only when the user turns that on, so most copies installed with Homebrew would never be updated.

Do not try `--zap` on a Mac you dictate on: it deletes the settings and the dictionary. The cask also quits Pladder by its bundle ID on uninstall and upgrade, so the copy you use is stopped too.

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
Check the menu bar menu. If it says the model is loading or downloading, wait. If it offers **Allow Accessibility Access…**, the grant is missing; it is keyed to the code signature, so a rebuild with an ad-hoc signature resets it.

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
