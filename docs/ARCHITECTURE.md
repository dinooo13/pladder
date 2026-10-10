# Architecture

How the code fits together, for a developer new to it. Why each choice was
made is in the Decisions table of [CLAUDE.md](../CLAUDE.md#decisions); why the
release-to-paste path is fast is in [PERFORMANCE.md](PERFORMANCE.md). This
file is the map: what runs where, in what order, and what each part relies on.

## Modules

| Target | Holds | Frameworks that matter |
|---|---|---|
| `PladderCore` | The coordinator, the hotkey trackers, the processors, the correction learner's logic, the settings, and the protocols every other part implements | Foundation; Observation for the coordinator's state |
| `PladderAudio` | Microphone capture and resampling | AVFoundation |
| `PladderEngines` | `FluidAudioIncrementalEngine` and the engine catalog | FluidAudio |
| `PladderSystem` | Hotkey monitors, paste, the Accessibility observer, output mute, key names, permissions, the transcript's language guess, the login item | AppKit, Carbon, CoreAudio, NaturalLanguage, ServiceManagement |
| `PladderRefine` | The polish models, their downloads and the correction reviewer | FoundationModels, llama.cpp, NaturalLanguage, CryptoKit |
| `Pladder` | The app: composition, menu, overlay, settings window, every user-facing sentence but the key names, which `PladderSystem` words from `KeyNames.xcstrings` | SwiftUI, AppKit |
| `PladderCLI` | `pladder-cli` | Everything but the app |
| `PladderBench` | Word error rate for the benchmarks | Foundation |

Core emits enum cases (`UnavailableReason`, `EngineFailure`,
`DictationFailure`, `HotkeyWarning`) and the app words them in
`Sources/Pladder/StatusText.swift`.

## Dictation flow

`DictationCoordinator` is the state machine. It is `@MainActor`, owns no I/O,
and gets every dependency injected, its clock included, so the tests drive
its timers with `ManualClock`.

**Key-down** (`hotkeyPressed`). The coordinator, in this order:

1. takes the engine that is ready now as the cycle's engine, and reads the
   polish toggle and the overlay style once, so a settings change
   mid-recording cannot change this cycle;
2. flips the state to `.recording`, before the first `await`, so the overlay
   reacts at once and a second press cannot start the microphone twice, and
   numbers the recording (`recordingID`). After every wait below the press
   checks it is still the current recording, and stops if a cancel ended it
   meanwhile;
3. turns Escape into the cancel key, waits for every earlier cancel still
   running, and starts the capture;
4. arms the output mute and starts the key-down work: the clipboard snapshot
   and the polish model's load;
5. starts the engine work. A streaming engine begins an utterance and gets a
   feed loop. In the other styles the loop wakes every second and hands the
   engine the audio captured since. With the Live Transcript style it skips
   that second: each turn hands over what has been captured, asks for the
   text so far, publishes it as `partialTranscript` and then waits half a
   second, so audio goes in on the live-pass cadence. Outside Live
   Transcript a warm loop transcribes half a second of silence every two
   seconds, which keeps the Neural Engine from going cold. A batch engine,
   or a streaming one that could not begin, gets only the warm loop and is
   transcribed whole at release;
6. starts the level meter and the 10 minute cap.

**Release** (`hotkeyReleased`). `endRecording()` stops everything the press
started: the gesture tracker, the cancel key, the meter, the cap, the feed,
the warm loop, the partial text and the mute. It is synchronous and every
call in it only flips a flag, cancels a task or spawns one, so nothing waits
before `recordingStopped` is emitted. The state becomes `.transcribing` and
the rest runs in `inFlight`:

1. wait for the feed loop to exit. A chunk it drained just before the
   release is still handed over, so every sample reaches the engine once and
   in order. This wait counts as engine time;
2. stop the capture, which returns only the samples after the last drain;
3. `finish`: drop a recording under 0.3 s, then `endUtterance` with the tail
   (or `transcribe` the whole buffer), run the processor pipeline, polish if
   the cycle asked for it and the text has four words or more, append the
   trailing space, and `insert`.

`inserted` carries the timing of every stage; the app turns it into the
release-to-paste log line (`TimingLine.swift`).

**Ending without text.** `cancelRecording` covers Escape, an interrupted
press, a hotkey change and quitting. The microphone goes off first; the
engine drops the utterance only once the feed loop has exited, so no chunk
lands after it. Each cancel's cleanup then waits for the one before it, and a
press right after a cancel waits for the newest, so its microphone and
utterance start only after every earlier cancel has stopped its microphone
and dropped its utterance. A press that is itself cancelled while it waits
stops there and never starts the microphone. A hotkey change ends the
recording before the new monitor starts, so a press on the new stream finds
the machine idle and only waits for that cleanup.

**Engines swapped mid-cycle** are unloaded once the cycle ends: the running
cycle keeps the engine it started with.

**Quitting.** `shutdown()` drops a recording, lets a dictation already on
its way out finish, and waits for the speakers and the clipboard to be given
back. The app delegate gives it 3 s; SIGTERM ends the process 5 s after the
signal regardless.

## Engine

`TranscriptionEngine` is a batch engine; `StreamingTranscriptionEngine` adds
`beginUtterance`, `feed`, `endUtterance`, `abandonUtterance`, `warmPass` and
`livePass`. `EngineLoader` builds, loads, polls and swaps the engine;
`StandardEngines.entries` is the catalog the app, the settings picker and the
CLI read.

**The utterance handle.** `beginUtterance` returns an `Utterance`, and feed,
live pass, end and abandon name it; the contract is in CLAUDE.md's
pluggability rules. The engine is an actor and reentrant across its awaits,
so with one shared slot and no handle a cancelled recording's abandon that
landed after the next recording had begun dropped that one instead, and of
two overlapping begins the later assignment won and the other session was
never cancelled. `UtteranceSlot` holds the bookkeeping: `begin` claims the
slot before the first await and hands back the session it replaces;
`install` refuses a session whose begin was overtaken by another begin or
by an abandon, and the engine cancels that session and throws; a stale
handle's feed, live pass and abandon do nothing, and its end throws
`notLoaded`.

`FluidAudioIncrementalEngine` runs FluidAudio's batch windows while the user
speaks, through the fork's `IncrementalChunkProcessor`. The text is the
batch path's text; [PERFORMANCE.md](PERFORMANCE.md#why-length-used-to-cost-time)
explains why that holds and the paced benchmark checks it. A live pass
transcribes the tail of the recording that fits one model window, cut on a
5 s grid so the text a reader follows does not shift between passes; it
never touches the session. Model downloads and their recovery are in
[MODELS.md](MODELS.md).

## Hotkeys

Keyboard events go through four layers, each a value type in Core except the
monitor:

```
monitor (tap or Carbon) → HotkeyChordSet → HotkeyChordTracker per role
        → HotkeyMonitorEvent stream → coordinator → HotkeyGestureTracker
```

**Roles.** `HotkeyRole.dictate` is push-to-talk, `.toggle` the toggle chord.
A toggle chord equal to the dictate chord is not a second chord: it makes the
dictate chord hybrid.

**Chord tracker.** `HotkeyChordTracker` turns transitions into `.pressed`,
`.released(submit:)` and `.interrupted` for one chord. Every event carries the
full set of held modifiers, so a missed event cannot leave one stuck.

- A chord engages when one of its keys goes down and exactly its modifiers
  and at least its regular keys are held. Exactly is what keeps shortcuts
  working: Shift+Right Option is not Right Option. A chord with a regular key
  ignores modifier sides (Right Option+Space is Option+Space); a
  modifier-only chord does not.
- It disengages when a chord key goes up or another key goes down. Another
  key within the interruption window (1 s) of engaging is an interruption:
  the user typed Cmd+C, not a dictation. Later, it is an ordinary release.
- The regular key that completed the chord is swallowed, with its repeats
  and key-up, so the app never sees the Space of Option+Space.
- The send key, pressed while the chord is engaged, arms the release with
  `submit: true`. It is matched by side and swallowed.
- A lost key-up (Secure Event Input hides key events from the tap while
  `flagsChanged` still flows) must not leave a key held for good. Once the
  chord's modifiers are released, its regular key only counts after a fresh
  key-down; a key-down of a key still marked swallowed means its key-up was
  lost.

**Chord set.** `HotkeyChordSet` feeds every tracker every event; an event is
swallowed if any tracker swallows it. A keystroke that moves two trackers
reports every end before any press. The gesture tracker relies on that: it
ignores a press while another chord is held. Two chords that nest (Right
Command, and Right Command + Right Option) hand over from one to the other
the way one tracker treats a foreign modifier. While a recording is on, a
plain Escape, or Escape with the engaged chord's modifiers, is reported as
`.escape` and swallowed before the trackers see it; Cmd+Option+Escape passes.

**Gesture tracker.** `HotkeyGestureTracker` decides what a press or release
means for the recording, with no clock of its own. Each role has a mode:
hold (stop at release), toggle (latch at release), or hybrid (latch on a tap
under 400 ms, stop after a longer hold). Any press of any chord ends a
latched recording. Some Bluetooth keyboards report a held key as released
and pressed again a few milliseconds apart: a press within 50 ms of the same
chord's release is a bounce and never acts. The first bounce seen turns on
`deferReleases`, and from then on every stopping release waits 50 ms first
and is undone by a bounce inside that wait.

**Tap and Carbon.** `HotkeySource.choose` picks the monitor; `HotkeyRouter`
keeps both alive and swaps them as the Accessibility grant and Secure Event
Input change.

- `GlobalHotkeyMonitor` is an active `CGEvent` tap on its own run-loop
  thread. It matches any chord, swallows keys, and supports the send key and
  interruptions. It needs Accessibility, and under Secure Event Input it sees
  no key-downs.
- `CarbonHotkeyMonitor` uses `RegisterEventHotKey`, which needs no permission.
  It takes exactly one regular key, cannot tell sides apart, has no Fn and no
  send key, and never sees an interrupting key. Escape is registered as a hot
  key of its own while a recording is on, from the main queue so the release
  path never waits on the window server. `CarbonHotkeySession` packs each hot
  key's ID from the session's generation and the role, so an old session's
  events are not found, and forces each role's events to alternate.
- `HotkeyMonitorLifecycle` is the session bookkeeping both share: the OS
  resource is made on another thread after `start` returns, so it is adopted
  only if its session is still current.

Without Accessibility a stored chord Carbon cannot register is stood in for
by Option+Space (`DictationCoordinator.standInHotkey`); the stored chord is
never rewritten. A chord change runs `HotkeySource.choose` again at once,
with the last Secure Event Input reading, and hands the coordinator the new
chord, its stand-in and, when it changed, the other monitor together
(`update(_:standInHotkey:monitor:)`), in one restart. Left to the next
permission poll, a modifier-only chord recorded while Carbon had the hotkey
under Secure Event Input would sit on Carbon, which cannot register it, for
up to two seconds. `settings`, `standInHotkey` and `replaceHotkeyMonitor`
all go through `update`, which works out once whether the monitor restarts.

While a settings field records a chord the hotkey is suspended.
`HotkeyRecordingSlot` holds the one recording session: beginning in one
field ends the other's, and only the field holding the session resumes the
hotkey, also when the field is freed mid-recording.

## Paste and clipboard

`PasteboardOutput.insert` puts the transcript on the pasteboard and posts
Cmd+V, then returns. Everything after that runs on detached tasks, so a
cancelled caller cannot cut it short. Three parts: `PasteboardOutput` picks
the key and decides between pasting and copying, `ClipboardKeeper` owns the
user's clipboard, `KeyPoster` types the keys.

- **Before the paste.** `prepare()` runs at key-down and again at release. It
  snapshots the clipboard (every item, every representation, items over
  64 MB left out) and resolves which key types "v" in the current layout.
- **The transcript is a promise.** It goes on the pasteboard as
  `TranscriptPromise`, with the nspasteboard.org marker types, so clipboard
  managers skip it and the target app's read is reported back.
- **When the clipboard comes back.** 400 ms after Cmd+V if the transcript has
  been read by then; otherwise 200 ms after the last read; after 8 s if
  nothing reads it. A read never brings it back before 400 ms, because
  Chromium may read once early and again for the real paste. Back-to-back
  pastes carry the first snapshot forward; a copy the user made in between
  wins.
- **Return.** With the send key, Return is posted 50 ms after the target's
  first read, or at 400 ms if nothing has read by then. A Return still owed
  when the next paste starts goes out before that paste's Cmd+V.
- **Without Accessibility** the text is copied and stays; no restore, no
  Return.
- **A failed Cmd+V** puts the clipboard back at once, through the same
  restore: when every item of the user's clipboard was too large to keep,
  the transcript stays and the keeper holds it, so the next snapshot does
  not take it for the user's clipboard.
- **Quitting** (`flush`) waits as the timer would, for the read and 200 ms
  after it, no sooner than 400 ms after Cmd+V, but gives up on an app that
  has not read by that 400 ms floor, since a quit cannot wait out the cap:
  at most the floor plus the 200 ms settle.

## Muting the speakers

`OutputMuteController` decides when the default output device is muted;
`CoreAudioOutputMute` does it. Everything there is ordering:

- The mute lands 200 ms after key-down, so a tap-and-release never touches
  the speakers.
- Every mute switch is read first and only those that were off are turned
  on and later off again, so a device or channel the user muted stays muted.
- Start and end run on tasks nothing orders, so the end can arrive first.
  Each names its recording: an end disarms its session whenever it comes,
  and a start whose session has ended does nothing.
- The device that was muted is the one unmuted, even if the default output
  changed meanwhile.

## Processors

The pipeline is `StandardProcessors.entries`: filler remover, dictionary
replacer, custom-word corrector, whitespace normaliser, spoken punctuation.
It is rebuilt when the dictionary changes, the one setting it is built
from, never per dictation; which processors are switched off is read on
each run.

**Fillers.** Two tiers, so a real word is never removed. Universal tokens
("uh", "ähm", "hmm") are not words in English, German or Spanish and always
go. Gated tokens ("um", "eh") are words somewhere and go only when the
on-device language guess names a language in which they are fillers; no
confident guess means only the universal tier runs. A filler takes a comma
on either side with it; a full stop after it moves to the word before.

**Custom words.** A dictionary entry with an empty `from` is a term to
repair near misses of ("Chat G P T" → "ChatGPT"). Every position of the
transcript is tried as a run of one to four tokens, reduced to lowercase
ASCII letters and digits, and scored by edit distance over the longer
length, times 0.3 when the Soundex codes agree; under 0.18 it matches. Keys
of three characters or fewer must match exactly, Soundex buys at most one
edit on keys of five or fewer however long the candidate, so "soviet" never
becomes "Swift", and a single everyday word
(`CommonWords`) is never rewritten, since the speaker most likely said it. A
match never crosses punctuation, and a possessive "'s" is kept.

**Spoken punctuation.** Only phrases that are never ordinary words are taken
("question mark", "Fragezeichen"); "period", "Punkt" and "punto" stay words.
A phrase after an article ("add a semicolon"), or after an article or
demonstrative and an adjective describing a mark ("the Oxford comma"), is
the noun, not a mark. German "ein" counts only with such an adjective ("ein
großes Fragezeichen"): it is also the separable prefix that ends "Schaltest
du das Licht ein", where the mark after it is dictated. Spanish "coma"
needs the language guess. It runs last because the whitespace step would
fold "new paragraph" back into a space.

## Polish

The polish toggle sends a dictation of four words or more through a model
before the paste. `PolishRouter` is the coordinator's one refiner and hands
each call to the model the settings name; `PolishModelController` owns the
model's file and memory.

- **The budget.** 8 s from when the polish starts, after the engine and the
  processors, covering the model's load and every chunk; past it, or on any
  failure, the text is pasted as dictated.
- **Chunks.** Long dictations are cut after sentence ends into windows that
  fit the model's context (about 300 words for Apple's, 250 for S1-mini),
  with a forced cut between words when a sentence runs too long.
- **Apple's model** (`TranscriptPolisher` on `OnDeviceLanguageModel`). A
  guided `@Generable` answer first, plain text once if that cannot be
  decoded. The session is prewarmed at key-down. Every call runs detached
  and is raced against the wall clock; a call abandoned at its deadline is
  drained by the next one, since the system model answers one request at a
  time. The race is `firstOf` in Core, which the app's quit uses too.
- **S1-mini** (`S1MiniPolisher` on `LlamaModel`). llama.cpp on the GPU,
  greedy, with the fixed prompt prefix decoded once at load and its cache
  kept. The model loads at the first key-down after it is chosen and stays
  loaded until polish is turned off or another model is picked. A load
  still running then is dropped once it finishes, and the next load waits
  for it, so two models are never resident at once.
- **The file.** `PolishModelController` downloads it only while polish is
  on and the model chosen, and cancels the download when either changes,
  in the order the settings changed. A cancel returns once the download
  has wound down; while it is verifying, the checksum stops at its next
  16 MB chunk, so the next model's download does not queue behind 1.5 GB
  of hashing.

Neither logs the transcript: log lines carry numbers and error case names.

## Learned corrections

After a paste that stayed in its field, the app watches what the user does to
the text and may offer a dictionary rule. Nothing of it runs before Cmd+V is
posted. `CorrectionLearner` runs the stages in order, each cheaper than the
next:

1. **Reviewer available?** Without Apple Intelligence the field is not even
   watched.
2. **Watch** (`AXPasteObserver`). On its own thread, since every AX call
   blocks on the target app. Find the paste just before the caret (retried a
   few times: apps paste on their own run loop), then read only a window of
   the paste plus a margin either side, after every value change, for up to
   60 s or until focus leaves. Chromium and Electron are asked for their
   accessibility tree once per app if they expose no focus. A new paste ends
   the watch in progress, which still returns what it saw.
3. **Diff** (`CorrectionDiff`). Tokens are words and single punctuation
   marks. The window as found is aligned against the last reading that still
   holds most of it (an emptied field means the message was sent; the
   reading before counts). A changed span is a candidate only when both
   sides are one or two words, it lies inside the paste, holds no
   punctuation, and changes more than case. More than three changes, or more
   than half the paste, is a rewrite and yields nothing.
4. **Known?** Pairs already in the dictionary or dismissed before
   (`dismissed-corrections.json`) are dropped.
5. **Sounds alike?** `PhoneticGate`: Soundex or an edit distance of two at
   most; one for short words.
6. **Review.** The on-device model says whether the corrected text is a
   name or term, which a rule suits, or an ordinary word whose spelling
   depends on the sentence. Reviews wait while a dictation is in flight, so
   they never eat into a polish.
7. **Propose.** At most three per paste, as menu lines; Add merges the rule
   into the dictionary.

## Settings file

`Settings` is persisted as JSON by `SettingsStore`, and nothing the user
wrote is lost to a load or a save:

- **Lenient decoding.** The decoder starts from the defaults and takes every
  key it can read, one at a time. A value it cannot read (a case a newer
  build added, a hand edit, one damaged dictionary row) keeps its default.
  Only a file that is not a JSON object fails.
- **Backups.** A file that decoded with something dropped is copied to
  `settings.broken-<time>.json`; one that failed is moved there. Names never
  collide, so an older backup is never replaced, and a file already backed
  up byte for byte is not copied again: an older build launched every day
  against a newer build's file would otherwise add a copy per launch.
- **Unknown keys survive.** A save merges into the existing file, keeping
  keys this build does not know, because two worktrees' builds share it.
  A key this build knows but could not read keeps the file's value too, as
  long as the settings still hold the default the load put in its place;
  once the user picks a value for it, theirs is written. Keys older
  versions wrote and nobody reads (`Settings.retiredKeys`) are dropped.

The coordinator sees only `DictationSettings`, and the app assigns a new
value only when that part changed. `PLADDER_SETTINGS_PATH` points a test copy
at a file of its own.

## The app

`AppModel` is the composition root. It builds the engine registry, the
settings store, the coordinator and the parts around it, owns the settings,
and turns the coordinator's events into sounds, log lines and learning. The
parts split off it:

- `HotkeyRouter` picks the tap or Carbon and applies the stand-in chord.
- `PermissionMonitor` polls Accessibility, the microphone and Secure Event
  Input every two seconds for the app's life.
- `PolishModelController` owns the polish model, its download and its memory.
- `CorrectionInbox` holds the learned-correction proposals.
- `SettingsLocation` says where the files are; the overlay demo and the
  screenshots get a throwaway directory.
- `OverlayController` drives the pill.
- `StatusText.swift` holds every sentence the menu, overlay and settings show.

Views talk to `AppModel` and its parts, never to the coordinator.

## The overlay

`OverlayController` mirrors the coordinator's state onto `OverlayModel`,
which the pill renders in an `OverlayPanel` that never takes focus.

- **Arrival.** The pill appears 150 ms into a recording, so a Cmd+C that the
  interruption rule cancels never shows it. It flies up from the bottom edge
  as the Minimal disc and expands into its style.
- **Release.** The model is left as it was, so the recording row gathers
  into the disc and dives; the paste is the confirmation. If nothing has
  been pasted by the time the disc has gathered, it waits with a spinner
  until the coordinator goes idle.
- **Polish** keeps the pill up and says "Polishing…" until idle.
- **The clipboard hint and errors** show in every style, Menu Bar included,
  and fade in where the pill rests; a failed paste must never be silent.
- **Menu Bar style** shows nothing else; the menu bar glyph is the feedback.

`scripts/overlay-demo.sh` plays every path with stand-ins and records it.

## pladder-cli

A developer tool; the user-facing part is in [INSTALL.md](../INSTALL.md).
Errors and progress go to stderr, so stdout holds only results.

| Command | Does |
|---|---|
| `pladder-cli <audio file>` | Prints the transcript and nothing else. `--process` runs the app's processors with the app's dictionary and toggles (read from its settings file or `PLADDER_SETTINGS_PATH`, never written); `--verbose` adds load and processing times. |
| `bench <fixtures dir>` | The whole-buffer benchmark. `--runs N` (default 6, first discarded; 11 to settle a result near the noise line), `--pause S` (idle seconds before every run, default 10). |
| `bench <dir> --paced` | Feeds each fixture in one-second chunks at real time and times `endUtterance`; also transcribes it whole and reports whether the texts are identical. Skips fixtures under 13 s unless `--all`. `--live` adds the Live Transcript pass every 0.5 s and reports its cost. |
| `bench-process <dir>` | Times the processor pipeline on the fixtures' scripts, with a filler in every sentence and with a spoken question mark too. `--runs N`, default 31. |
| `polish <text file \| ->` | Runs a polish model over one transcript, cold and then warm. `--model apple\|s1-mini\|s1-mini-8bit`, `--instructions <file>` (Apple), `--gguf <file>` (any S1-mini-family model), `--control <line>` (S1-mini). |
| `polish-set <set.json>` | Runs a polish model over a test set after the app's processors: every answer, word error rate per language, exact matches, timings. `--model`, `--gguf` and `--control` as for `polish`; no `--instructions`. |

Fixtures are audio files with a sibling `.txt` holding the script, made by
`scripts/make-fixtures.sh`. The procedures are in
[BENCHMARKS.md](BENCHMARKS.md).
