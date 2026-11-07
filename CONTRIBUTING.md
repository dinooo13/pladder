# Contributing

Thanks for wanting to help. Pladder is small on purpose, so the most useful thing to know before writing code is what it optimises for, in this order:

1. **The release-to-paste time.** Everything between letting go of the key and the paste. Nothing goes on that path without a before-and-after benchmark.
2. **A minimal UI.** No new setting, window or overlay element unless a feature cannot work without it. Removing beats adding.
3. **Privacy.** Audio and text never leave the Mac. No telemetry, no accounts. The only requests are the one-time model downloads from Hugging Face and the update check against this repository's releases, and they stay the only ones.

A change that trades one of these for convenience will probably be turned down, however well it is written.

## Before you write code

Open an issue first. There are two templates:

- **Proposal**, for a feature or a change: the goal, what is there today, the proposal, what is out of scope, and when it is done. A short discussion there saves a pull request that goes the wrong way.
- **Bug report**: what happens, how to reproduce it, how often, your setup, and for a slow paste the release-to-paste log lines.

Typos, broken links and obvious one-line fixes can go straight to a pull request. A security problem does not go in an issue: see [SECURITY.md](SECURITY.md).

## Building and testing

You need macOS 26 on Apple Silicon and Xcode 26.

```sh
swift build                          # debug build
swift test                           # unit tests, well under a second
./scripts/bundle.sh --run            # release build, signed, in dist/Pladder.app
```

[INSTALL.md](INSTALL.md#building-for-development) covers signing, permissions and the command-line tool. If you dictate with an installed Pladder while you work, run your build with its own settings file and a different chord, so the two never fire together; the "Working on this Mac while Pladder is in use" section of [CLAUDE.md](CLAUDE.md) shows how, and how to stop only your copy.

## How the code is laid out

[CLAUDE.md](CLAUDE.md) holds the decisions and the reasons for them, the rules for adding an engine, processor, polish model, hotkey role or language, and the code style. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the parts fit together. Read the rules for the part you touch before you start; they are short.

A few rules catch most first pull requests:

- `PladderCore` imports Foundation and Observation only, and holds no user-facing strings. It emits enum cases, and `Sources/Pladder/StatusText.swift` words them.
- A new user-facing string is keyed by its exact English text in the String Catalog. German is maintained alongside English; add the German if you can, or say in the pull request that it is missing.
- A comment stays only when it says something the code cannot: a constraint from macOS or a framework, a measured number, or a trap. No narration, no history.
- `swift build` must stay free of warnings. CI fails on one.

## The benchmark rule

If your change touches anything between `recordingStopped` and `inserted` in `DictationCoordinator`, a processor, or the engine, run the benchmark before and after and put both results in the pull request. The procedure and the M1 baseline are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md#procedure). A difference under about ten percent is noise. If nothing on that path changed, say so in one line.

## Commits

Pull requests are rebased onto `main`, so every commit lands as it is, and the release notes are built from the commit subjects by `scripts/changelog.sh`. So each commit should:

- Start its subject with the area it touches, a colon and a sentence: `Hotkeys: …`, `Overlay: …`, `Processors: …`, `Tests: …`, `CI: …`, `Docs: …`, `Site: …`. `git log --oneline` shows the areas in use.
- Say in the body why, not what, wrapped at about 72 columns, and end with `Closes #<issue>.` when it closes one.
- Build and pass the tests on its own.

Squash fixups before you ask for a review.

## Pull requests

The template asks for the same things the recent pull requests show: why the change is needed, what changed, how you checked it, and the benchmark or the line saying none was needed. Keep a pull request to one concern; a second fix noticed along the way is its own issue.

CI runs `build-and-test`, `doc-pointers` and `scripts` on every pull request, and all three must pass. A comment that points at a heading in `docs/` is checked to exist, so rename a heading only together with its pointers.

## Licence

Pladder is MIT licensed. By opening a pull request you agree that your contribution is released under the same [licence](LICENSE).
