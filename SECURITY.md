# Security policy

## Nothing leaves your Mac

Pladder has no server, no account, no telemetry and no crash reporter. Your audio and your words never leave the Mac, so there is no copy of them anywhere else to leak, subpoena or breach.

- **Two kinds of request.** One-time model downloads from Hugging Face: the speech model at first launch, and S1-mini only if you pick it for polish. After that it works with Wi-Fi off. And the update check against this repository's releases, which runs when you choose Check for Updates…, or once a day if you turn automatic checks on in Settings; it fetches `appcast.xml` and sends nothing about you. Its own download code is [`ModelFiles.swift`](Sources/PladderRefine/ModelFiles.swift); the speech model comes through FluidAudio's downloader, the updates through [Sparkle](https://sparkle-project.org), which installs an update only when both its Developer ID and its EdDSA signature are valid.
- **Audio stays in memory.** The microphone is open only while you hold the key, and macOS shows its orange indicator only then. Audio goes from the microphone to the Neural Engine and is dropped. It is never written to disk.
- **Text is kept only as long as the paste needs it.** The transcript goes onto the clipboard for the paste, and your old clipboard comes back once the target app has read it. Pladder's log holds timings and word counts, never words.
- **Everything else is on disk only on your Mac**: your settings, your dictionary, the corrections you dismissed, and the downloaded models, under `~/Library/Application Support/Pladder`.
- **Open source, signed and notarised.** Every line is in this repository under the MIT licence. Releases are built by a GitHub Actions workflow from `main`, signed with a Developer ID, run with the hardened runtime and notarised by Apple.

[docs/PRIVACY.md](docs/PRIVACY.md) follows your words through the app step by step.

### What Pladder has to trust

Being honest about the edges is part of the model:

- **Accessibility.** The global hotkey and the paste need it, and the App Sandbox does not allow it, so Pladder is not sandboxed. With it, Pladder can see key events and read the field it pasted into; it uses the first only to match your hotkey, and the second only to notice a correction to the words it just pasted.
- **The model downloads.** S1-mini is pinned to a commit and used only if its SHA-256 matches. The speech model comes from the main branch of FluidAudio's Hugging Face repository and is checked by size only.

## Supported versions

Only the [latest release](https://github.com/dinooo13/pladder/releases/latest) gets fixes. Choose Check for Updates… in the menu to get one, or turn on automatic checks in Settings.

## Reporting a vulnerability

Please do not open a public issue. Report it privately on GitHub instead: on the repository's **Security** tab choose **Report a vulnerability**, or go straight to [the form](https://github.com/dinooo13/pladder/security/advisories/new).

Say what you found, the steps to reproduce it, which version and macOS you ran, and what an attacker gains. You will get an answer within a week. Once a fix is released, the advisory is published with credit to you, unless you would rather not be named.

These matter most, because they would break the promises above:

- Audio or text leaving the Mac, or any network request other than the model downloads.
- A downloaded model file used without its check, or loaded from somewhere other than its source.
- The microphone staying on after a recording has ended, or audio or a transcript written to disk.
- Text pasted into, or read from, a place you did not dictate into, or the clipboard keeping a transcript or losing its old contents beyond the documented timings.
- Another app or user on the Mac using Pladder's permissions through it: its settings file, its command-line tool or its event tap.
- A signed release that is not what this repository builds.

A bug that needs an attacker who already runs code as you, with Accessibility granted, is worth a normal issue rather than an advisory.
