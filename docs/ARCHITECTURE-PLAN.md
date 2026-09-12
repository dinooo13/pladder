# Architecture and performance plan

A step-by-step plan, written so that it can be handed to an implementer who
has not read the codebase. It has two parts. Part A closes the gaps found in
the September 2026 architecture review. Part B is a ranked list of speed
experiments for the release-to-paste path, each with a measurement gate.
Step A1 comes first because Part B cannot be judged without it.

Every step is one pull request. Do the steps in order; each assumes the ones
before it have landed.

## Ground rules for the implementer

Read `CLAUDE.md` first. In addition:

1. **Never** run `pkill -x Pladder`, `killall Pladder`, `bundle.sh --run` or
   `bundle.sh --install` unless the developer asked for it in the same
   message. The developer's own copy of the app is running and in use.
2. **Never** post synthetic key events. The developer records the real-app
   measurements; you prepare the build and the code.
3. `PladderCore` imports Foundation only. If a change needs AppKit,
   AVFoundation or FluidAudio, it belongs in `PladderSystem`, `PladderAudio`
   or `PladderEngines`.
4. After every step: `swift build`, then `swift test`. Both must pass before
   the pull request is opened. `swift test` finishes in about a second.
5. Any step marked **critical path** changes code between the coordinator's
   `recordingStopped` and `inserted` events. For those, run
   `swift run -c release pladder-cli bench bench/fixtures` before and after
   and put both tables in the pull request, as `CLAUDE.md` requires. The
   bench only measures the engine, so it will not move for most of these
   steps; say so in the PR and attach the log-line figures from step A1
   instead, which the developer collects.
6. Do not add settings, windows or overlay elements. Do not edit
   `docs/ARCHITECTURE-REVIEW.md`; this plan supersedes it.
7. Keep each pull request to the step described. If something else looks
   wrong, write it down in the PR description and leave it alone.

## How the app measures itself today

`DictationCoordinator` emits four events. `AppModel.handle` stamps
`recordingStopped` and `inserted` and logs the difference as the
release-to-paste time, with the engine's own `processingTime` beside it.
Read it with:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```

The only end-to-end number is that one line. There is no way today to see
how the non-engine part splits between capture stop, processors and paste.
Step A1 fixes that.

---

# Part A: architecture

## A1. Log every stage of the release-to-paste path

**Why.** The gap between total and engine time is where Part B's smaller
changes live. Without a per-stage breakdown none of them can be judged.

**Files.** `Sources/PladderCore/DictationCoordinator.swift`,
`Sources/Pladder/AppModel.swift`, `Tests/PladderCoreTests/DictationCoordinatorTests.swift`.

**Changes.**

1. In `DictationCoordinator`, add a value type next to `Event`:

   ```swift
   /// Wall-clock time of each stage between the hotkey release and the paste.
   public struct CycleTiming: Sendable, Equatable {
       public var captureStop: Duration
       public var engine: Duration
       public var processing: Duration
       public var insert: Duration
   }
   ```

2. Change the event case `inserted(Transcript)` to
   `inserted(Transcript, CycleTiming)`.

3. In `hotkeyReleased`, wrap `capture.stop()` with `ContinuousClock.now`
   reads and pass the elapsed `Duration` into `finish`. In `finish`, time
   `engine.transcribe`, the pipeline `run`, and `output.insert` the same way.
   Build a `CycleTiming` and pass it in the `.inserted` event. Reading the
   clock costs nanoseconds; nothing else on the path changes.

4. In `AppModel.handle`, extend the log line so it reads, for example:

   ```
   release-to-paste 0.312 s: stop 0.012, engine 0.250, process 0.003, paste 0.014; audio 4.2 s
   ```

   Keep the existing `total` computed from the event stamps. Use
   `Self.seconds(_:)` for each `Duration`.

5. Update `docs/BENCHMARKS.md`, section "Reading the app's release-to-paste
   log", to show the new line and say what each stage contains:
   `stop` is `AudioCapture.stop()`, `engine` is `transcribe`, `process` is
   the processor pipeline, `paste` is `TextOutput.insert`. The remainder of
   the total is actor scheduling.

**Tests.** Add one test to `DictationCoordinatorTests`: run a full cycle with
an `onEvent` closure that records events, and assert that the `.inserted`
event carries a timing whose `engine` value is at least the echo engine's
delay. Existing tests that construct the coordinator without `onEvent` need
no change.

**Done when.** Build and tests pass; the developer confirms the new log line
appears for a real dictation.

**Critical path:** yes, formally. Run the bench once for the record.

## A2. Characterisation tests for behaviour that has none

**Why.** Steps A3 to A5 refactor the coordinator. These tests pin the
behaviour that is currently only covered by reading the code.

**Files.** `Tests/PladderCoreTests/DictationCoordinatorTests.swift`,
`Sources/PladderCore/EchoEngine.swift`.

**Changes.**

1. Add a test engine in the fakes section of the test file:

   ```swift
   /// Fails `load()` a set number of times, then succeeds.
   actor FlakyEngine: TranscriptionEngine {
       nonisolated let id = EngineID("flaky")
       nonisolated let displayName = "Flaky"
       private(set) var status: EngineStatus = .unloaded
       private var failuresRemaining: Int
       init(failures: Int) { failuresRemaining = failures }
       struct LoadFailed: LocalizedError { var errorDescription: String? { "boom" } }
       func load() async throws {
           if failuresRemaining > 0 {
               failuresRemaining -= 1
               status = .failed(message: "boom")
               throw LoadFailed()
           }
           status = .ready
       }
       func transcribe(_ samples: [Float]) async throws -> Transcript {
           Transcript(text: "flaky", audioDuration: 1, processingTime: 0, engineID: id)
       }
       func unload() { status = .unloaded }
   }
   ```

2. Make `EchoEngine.transcribe` refuse to run before `load()` has finished,
   so it behaves like the real engine:

   ```swift
   public struct NotLoaded: LocalizedError {
       public var errorDescription: String? { "Speech model is not loaded yet." }
   }
   public func transcribe(_ samples: [Float]) async throws -> Transcript {
       guard status == .ready else { throw NotLoaded() }
       ...
   ```

   Run the tests. All existing ones must still pass, because every test that
   transcribes waits for `.idle` first.

3. Add these tests:

   - `engineLoadFailureShowsTheEngineMessage`: registry with
     `FlakyEngine(failures: 1)`; `c.start()`; expect
     `c.state == .unavailable(reason: "boom")` and
     `c.engineStatus == .failed(message: "boom")` within the usual wait.
   - `reloadAfterLoadFailureRecovers`: same setup, then `c.reloadEngine()`;
     expect `c.state == .idle`.
   - `suspendingTheHotkeyDropsTheRecording`: start, wait for idle,
     `await c.hotkeyPressed()`, set `c.isHotkeySuspended = true`; expect
     `c.state == .idle`, `capture.stopCount == 1`, `output.inserted.isEmpty`.
     Then set it back to `false`, call `hotkey.press()` on the `FakeHotkey`
     you passed in, and expect `c.state.isRecording`.

**Done when.** The three new tests pass, and every existing test passes.

**Critical path:** no.

## A3. Transcribe with the engine that was ready at release

**Why.** When the engine setting changes during a recording,
`settingsChanged` replaces `engine` at once and unloads the old one. `finish`
then transcribes with the new engine, which is still loading. With the real
engine that throws "Speech model is not loaded yet" and the dictation is
lost. The existing test `engineChangeWhileRecordingKeepsTheCycleAlive` passes
only because `EchoEngine` used to ignore its status; after A2 it fails.

**Files.** `Sources/PladderCore/DictationCoordinator.swift`, tests.

**Changes.**

1. In `hotkeyReleased`, capture the engine before starting the task and pass
   it into `finish`:

   ```swift
   let engine = self.engine
   inFlight = Task { [weak self] in
       guard let self else { return }
       ...
       await self.finish(audio, with: engine, ...)
   }
   ```

   `finish` gains a `with engine: any TranscriptionEngine` parameter and uses
   it instead of `self.engine`.

2. In `settingsChanged`, unload the previous engine only after any in-flight
   cycle has finished:

   ```swift
   let previous = engine
   let inFlight = self.inFlight
   Task {
       await inFlight?.value
       await previous.unload()
   }
   ```

3. Add a private helper and use it wherever a cycle ends (`finish` has three
   exits, `cancelRecording` has one, and the error-reset task has one):

   ```swift
   /// Idle if the engine can take another dictation, otherwise unavailable
   /// with the engine's own reason.
   private func becomeIdle() {
       switch engineStatus {
       case .ready: state = .idle
       case .failed(let message): state = .unavailable(reason: message)
       case .unloaded, .downloading, .loading: state = .unavailable(reason: "Loading model")
       }
   }
   ```

   Do not change `setEngineStatus`.

4. While in `finish`, replace the force unwrap:

   ```swift
   let needsSpace = settings.appendTrailingSpace && processed.last?.isWhitespace == false
   ```

**Tests.** Add `engineChangeWhileRecordingUsesTheEngineThatRecorded`: registry
with echo "one" (5 ms delay) and a second entry `EngineID("two")` whose
`EchoEngine` has a 500 ms delay. Start, wait for idle, press, set
`c.settings.engineID = EngineID("two")`, release, `await c.inFlight?.value`.
Expect `output.inserted == ["one"]` (set `appendTrailingSpace = false`) and
that `c.state` ends as `.unavailable(reason: "Loading model")` or `.idle`
depending on whether "two" has loaded. Keep the existing engine-change test.

**Done when.** New test passes, all tests pass.

**Critical path:** yes. `finish` is on it. The change adds one parameter
and removes one force unwrap; run the bench for the record and attach ten
log lines before and after from the developer.

## A4. Build the processor pipeline when settings change, not per dictation

**Why.** `finish` calls `makePipeline(settings)` on every dictation, which
constructs every processor and compiles one regular expression per
dictionary entry, on the main actor, on the critical path. It is the one
place the codebase breaks its own first rule. The same change removes the
`DictionaryReplacer` special case and the placeholder-entry comment in
`AppModel`.

**Files.** `Sources/PladderCore/DictationCoordinator.swift`,
`Sources/Pladder/AppModel.swift`, `CLAUDE.md`, tests.

**Changes.**

1. In `DictationCoordinator`, add `private var pipeline: ProcessorPipeline`,
   set it in `init` from `makePipeline(settings)`, and rebuild it at the top
   of `settingsChanged`:

   ```swift
   private func settingsChanged(from old: Settings) {
       // Rebuilt here so that no processor is constructed on the
       // release-to-paste path; `DictionaryReplacer` compiles a regex per entry.
       pipeline = makePipeline(settings)
       ...
   ```

   `AppModel.settings` already ignores assignments that change nothing, so
   this runs only on real changes. Keep `disabledProcessors` as a run-time
   argument to `run`, as today.

2. In `finish`, replace the `makePipeline(settings).run(...)` call with
   `pipeline.run(transcript.text, disabled: settings.disabledProcessors)`.

3. In `AppModel.init`, replace the `processorOrder` array and the
   `makePipeline` closure:

   ```swift
   let initial = store.load()

   // Processors, in pipeline order: fillers go first so the dictionary sees
   // cleaned text, and whitespace is tidied last. Each entry is a factory so
   // a processor that needs settings builds itself from them; nothing here
   // knows which processor that is.
   let processorFactories: [@Sendable (Settings) -> any TextProcessor] = [
       { _ in FillerRemover() },
       { DictionaryReplacer(entries: $0.dictionary) },
       { _ in WhitespaceNormalizer() },
   ]
   self.processors = processorFactories.map { $0(initial) }
   ...
   coordinator = DictationCoordinator(
       settings: initial,
       ...
       makePipeline: { s in ProcessorPipeline(processorFactories.map { $0(s) }) },
   ```

   Delete the comment about placeholder entries.

4. In `CLAUDE.md`, "Pluggability rules", change the processor line to:
   "Adding a processor: implement `TextProcessor` in its own file, append a
   factory to `processorFactories` in `AppModel`. The pipeline is rebuilt
   when settings change, never per dictation."

**Tests.** Add `dictionaryChangeAfterStartIsUsedByTheNextDictation`: start
with an empty dictionary, wait for idle, set
`c.settings.dictionary = [DictionaryEntry(from: "hello", to: "bye")]`, run a
cycle with echo text "hello world", expect the output contains "bye world".
This is the test that catches a stale cache.

**Done when.** Tests pass; `AppModel` no longer mentions
`DictionaryReplacer.processorID`.

**Critical path:** yes, and this one is expected to move. Attach the bench
tables and the developer's log lines. The `process` stage should fall to
about zero with a populated dictionary.

## A5. Extract engine loading from the coordinator

**Why.** The coordinator holds the state machine plus engine construction,
loading, status polling and swapping. Moving the engine lifecycle into its
own Foundation-only class leaves the coordinator with the state machine and
wiring, and gives the loader its own tests. This is a move, not a redesign:
the polling stays, because `TranscriptionEngine` exposes only a status
getter and requiring a stream from every engine is not worth it for one
engine.

**Files.** New `Sources/PladderCore/EngineLoader.swift`, new
`Tests/PladderCoreTests/EngineLoaderTests.swift`,
`Sources/PladderCore/DictationCoordinator.swift`.

**Changes.**

1. Create `EngineLoader`:

   ```swift
   import Foundation

   /// Owns the current engine and its load lifecycle: builds it from the
   /// registry, loads it, polls its status while loading, and swaps it on
   /// request. Foundation only; the coordinator subscribes for status.
   @MainActor
   public final class EngineLoader {
       public private(set) var engine: any TranscriptionEngine
       public private(set) var status: EngineStatus = .unloaded
       /// Called on the main actor each time `status` changes.
       public var onStatusChange: (EngineStatus) -> Void = { _ in }

       private let registry: EngineRegistry
       private var pollTask: Task<Void, Never>?

       public init(registry: EngineRegistry, engineID: EngineID) {
           guard let engine = registry.make(engineID) else {
               preconditionFailure("EngineRegistry has no engines")
           }
           self.registry = registry
           self.engine = engine
       }

       /// Loads the current engine, or re-runs a failed load.
       public func load() { /* body of the old loadEngine + pollStatus */ }

       /// Switches to `id` and starts loading it. Returns the engine being
       /// replaced so the caller can unload it once nothing is using it, or
       /// nil when the registry cannot build `id`.
       public func select(_ id: EngineID) -> (any TranscriptionEngine)? {
           guard let next = registry.make(id) else { return nil }
           let previous = engine
           engine = next
           status = .unloaded
           onStatusChange(status)
           load()
           return previous
       }

       public func stop() { pollTask?.cancel() }

       private func setStatus(_ new: EngineStatus) {
           guard new != status else { return }
           status = new
           onStatusChange(new)
       }
   }
   ```

   Move `loadEngine` and `pollStatus` from the coordinator into `load()`
   without changing their logic; replace `self.setEngineStatus(x)` with
   `self.setStatus(x)` and `statusTask` with `pollTask`. Do not add
   cancellation of the load itself; the original does not cancel it and
   neither engine handles that.

2. In `DictationCoordinator`:
   - Remove `engine`, `registry`, `statusTask`, `loadEngine`, `pollStatus`.
   - Add `private let loader: EngineLoader`. In `init`, after all other
     stored properties are set:
     `loader = EngineLoader(registry: registry, engineID: settings.engineID)`
     then `loader.onStatusChange = { [weak self] in self?.setEngineStatus($0) }`.
   - `start()` calls `loader.load()`; `reloadEngine()` calls `loader.load()`;
     `stop()` calls `loader.stop()`.
   - `hotkeyReleased` captures `loader.engine`.
   - The engine branch of `settingsChanged` becomes:

     ```swift
     if old.engineID != settings.engineID, let previous = loader.select(settings.engineID) {
         let inFlight = self.inFlight
         Task {
             await inFlight?.value
             await previous.unload()
         }
     }
     ```

     The state change to "Loading model" now arrives through
     `onStatusChange`, so the explicit assignment goes.
   - Keep `engineStatus` and `setEngineStatus` on the coordinator unchanged;
     the UI reads them.

3. The public `init` signature of the coordinator does not change, so no
   test helper changes.

**Tests.** `EngineLoaderTests` with four tests using `EchoEngine` and the
`FlakyEngine` from A2: `loadReachesReady`,
`loadFailureReportsTheEngineMessage`, `reloadAfterFailureRecovers`,
`selectReturnsThePreviousEngineAndLoadsTheNext`. Each collects statuses via
`onStatusChange` into an array and asserts on the last value.

**Done when.** All tests pass; `DictationCoordinator.swift` is about 250
lines; `grep -n "pollStatus\|statusTask" Sources/PladderCore/DictationCoordinator.swift`
returns nothing.

**Critical path:** no. The only path change is `loader.engine` for
`self.engine`.

## A6. Documentation

Update `CLAUDE.md`, "Pluggability rules", last bullet, to mention that the
engine lifecycle lives in `EngineLoader`. Add nothing else. If the developer
wants the review kept as history, it stays; otherwise delete
`docs/ARCHITECTURE-REVIEW.md` in this PR.

---

# Part B: speed of the release-to-paste path

Where the time goes today, for a five-second dictation on the M1 baseline:

| Stage | Estimate | Source |
|---|---:|---|
| Capture stop | 5 to 15 ms | `removeTap` plus `AVAudioEngine.pause()` |
| Engine | about 200 ms | 10 s fixture is 237 ms; roughly 150 ms fixed plus 8 ms per second of audio |
| Processors | 1 to 5 ms | pipeline build plus regex runs; A4 removes the build |
| Paste | 12 to 15 ms | pasteboard read, write, 10 ms sleep, event post |

The engine is at least four fifths of the total. Only B1 and B2 can change
that; B3 to B6 together are worth about 30 ms, which is ten percent and
therefore only visible once A1's per-stage figures exist.

**Measurement protocol for every item.** The developer dictates the same
sentence ten times per condition, about five seconds each, with the machine
otherwise quiet, and reads the A1 log lines. Compare medians per stage. A
change is kept when its stage figure drops and no dictation misbehaves; a
change that only reshuffles time between stages is reverted. B1 is also
covered by the CLI bench, which must be extended as described there.

## B2. Warm the Neural Engine on key-down (do this experiment first)

**Evidence.** `docs/BENCHMARKS.md` records the 10 s fixture at 150 ms when
runs are back to back and 237 ms after ten seconds of idle. Roughly 90 ms
of the per-call cost is the chip coming up from idle. A real dictation
always starts from idle, because the engine does nothing while the key is
held.

**Experiment.** In `DictationCoordinator.hotkeyPressed`, after
`onEvent(.recordingStarted)`, start a task that calls
`engine.transcribe(silence)` with 0.5 s of zeros and discards the result:

```swift
// Bring the Neural Engine up from idle while the user is still speaking.
Task.detached(priority: .utility) { _ = try? await engine.transcribe(warmup) }
```

where `warmup` is `[Float](repeating: 0, count: 8_000)`. The engine actor
serialises calls, so a real transcription queues behind an unfinished
warm-up; that costs at most the warm-up's own remaining time.

**Gate.** Ten dictations of about five seconds, with and without. Keep it
if the `engine` stage drops by ten percent or more. If it does not, try a
second variant that repeats the warm-up call every two seconds while
recording, and keep that only on the same gate. If neither helps, the idle
cost is not where the benchmark suggests and B1 is the only engine lever.

**Risk.** A warm-up call on the engine actor while the real call is queued.
Bounded by the warm-up length, well under the 300 ms minimum recording.
If B1 lands, B2 is removed again: the encoder runs during recording anyway.

**Critical path:** yes, because the warm-up can delay the real call.

## B1. Transcribe while the user is still speaking

**Evidence.** FluidAudio ships `SlidingWindowAsrManager`
(`.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/`),
which runs the same Parakeet TDT v3 models in overlapping windows as audio
arrives. It takes the already-downloaded `AsrModels` via
`loadModels(_ models:)`, so there is no second download. Audio goes in with
`streamAudio(AVAudioPCMBuffer)` and `finish()` returns the full text. At
release, only the audio since the last completed window is left to encode.
For a 60 s dictation that means roughly 100 ms instead of 560 ms; for a 5 s
dictation, the encoder work for the first windows is already done.

**Design.** Add a streaming capability without touching the existing
engine, so both can be benchmarked side by side and the default stays as it
is until the numbers say otherwise.

1. `PladderCore`, new protocol in `Protocols/TranscriptionEngine.swift`:

   ```swift
   /// An engine that can consume audio while it is being recorded, so that
   /// only the tail remains to transcribe on release.
   public protocol StreamingTranscriptionEngine: TranscriptionEngine {
       /// Start a new utterance. Called when recording starts.
       func beginUtterance() async throws
       /// Feed 16 kHz mono samples captured since the last call.
       func feed(_ samples: [Float]) async
       /// Feed the final samples and return the transcript for the whole utterance.
       func endUtterance(_ tail: [Float]) async throws -> Transcript
       /// Drop the utterance without a transcript.
       func abandonUtterance() async
   }
   ```

2. `PladderCore`, `AudioCapture` gains one requirement:

   ```swift
   /// Returns the samples captured since `start()` or the previous `drain()`,
   /// and clears them. `stop()` then returns only what arrived after the
   /// last drain.
   func drain() async -> [Float]
   ```

   `AVAudioEngineCapture` implements it with the existing
   `TapProcessor.drain()`. `FakeCapture` in the tests returns an empty array
   unless a test sets samples for it.

3. `PladderEngines`, new file `FluidAudioStreamingEngine.swift`: an actor
   conforming to `StreamingTranscriptionEngine`. `load()` downloads via
   `AsrModels.downloadAndLoad` exactly as `FluidAudioEngine` does, then
   builds a `SlidingWindowAsrManager(config: .default)` and calls
   `loadModels(models)`. `beginUtterance` calls `startStreaming(source:
   .microphone)` (the source is a label; audio is pushed by us).
   `feed` wraps the samples into a 16 kHz mono `AVAudioPCMBuffer` and calls
   `streamAudio`. `endUtterance` feeds the tail, times `finish()`, and
   returns a `Transcript` whose `processingTime` is that duration and whose
   `audioDuration` is the sum of everything fed. `abandonUtterance` calls
   `cancel()`. `transcribe(_:)` (the base protocol requirement) is
   implemented as begin, feed everything, end, so the CLI and tests can
   still call it. Register it in `AppModel` as a second entry:
   "Parakeet TDT v3 (streaming)".

4. `DictationCoordinator`:
   - In `hotkeyPressed`, if `loader.engine is any StreamingTranscriptionEngine`,
     call `beginUtterance()` and start a `feedTask` that loops: sleep one
     second, `let chunk = await capture.drain()`, `await engine.feed(chunk)`,
     accumulating `fedSampleCount`. Cancel the task in `hotkeyReleased` and
     `cancelRecording`; in `cancelRecording` also call `abandonUtterance()`.
   - In `hotkeyReleased`, when the engine is streaming: cancel `feedTask`,
     then `let tail = await capture.stop()`, then
     `endUtterance(tail.samples)`. The minimum-duration check uses
     `fedSampleCount + tail.samples.count` divided by the sample rate.
   - Everything downstream of the transcript is unchanged.

5. `PladderCLI`: when the chosen engine is streaming, the bench pushes each
   fixture in one-second chunks paced at real time (so the manager processes
   windows as it would in the app), then times `endUtterance` only and
   reports that as the engine time, plus word error rate as today. Add a
   `--engine streaming` flag; default stays the batch engine. Because the
   pacing takes as long as the audio, run only the 10 s, 30 s and 60 s
   fixtures for the streaming engine.

**Gate.** Two numbers, both from the extended bench on the M1: the
`endUtterance` time must be under half of the batch engine time for the
same fixture, and word error rate must be within one point of the batch
engine on all three fixtures. Then ten real dictations per engine via the
A1 log. Only if both pass does the streaming engine become the default for
new installs (first registry entry). Existing settings files keep their
engine ID, so nobody is switched silently.

**Risks.**

- Accuracy. FluidAudio's own comments warn that v3 in streaming windows can
  emit wrong-script tokens (their issue 512) and the sliding window can
  drop or duplicate words at seams. The word error rate gate exists for
  this. `SlidingWindowAsrConfig` accepts a `language` hint; Pladder is
  multilingual, so leave it nil and let the gate decide.
- Power. The encoder runs while the key is held. On a Mac this is
  acceptable; note it in the PR.
- Complexity. This is the largest step in the plan. Keep it behind the
  protocol so the batch engine is untouched and reverting is one registry
  line.

**Critical path:** yes, the whole thing.

## B3. Take `AVAudioEngine.pause()` off the path

**Evidence.** `AVAudioEngineCapture.stop()` (`Sources/PladderAudio/AVAudioEngineCapture.swift:93-113`)
removes the tap, drains the samples, and then calls `engine.pause()` before
returning. Pausing stops the hardware I/O cycle and can block for one
device buffer, typically several milliseconds. The samples are complete
once the tap is removed and drained; the pause only exists to turn the
microphone indicator off.

**Change.** Return the captured audio first and pause afterwards on the
actor:

```swift
let audio = CapturedAudio(samples: samples)
// Off the release-to-paste path: the indicator going off a few
// milliseconds later is invisible, the pause blocking here is not.
Task { [weak self] in
    guard let self else { return }
    await self.pauseIfIdle()
}
return audio

private func pauseIfIdle() {
    // A new recording may have started while this was queued.
    guard !isRecording else { return }
    engine.pause()
}
```

`startEngineIfNeeded` already skips `engine.start()` when the engine is
running, so a back-to-back start before the deferred pause runs is safe
because the pause checks `isRecording` first.

**Gate.** The `stop` stage in the A1 log. Keep if it drops. Also confirm
the microphone indicator still goes off after every dictation.

**Critical path:** yes.

## B4. Remove or shrink the 10 ms sleep before Cmd+V

**Evidence.** `PasteboardOutput.insert` sleeps `propagationDelay` (10 ms)
between writing the pasteboard and posting Cmd+V
(`Sources/PladderSystem/PasteboardOutput.swift:42,86`). The comment says the
write is synchronous with the pasteboard server. The key event then travels
through the window server to the target app, which is later still. The
sleep is a fixed cost on every dictation, plus `Task.sleep` scheduling slop.

**Change.** Make `propagationDelay` an initialiser parameter defaulting to
zero. If the developer sees a stale paste in any app, set it to 2 ms and
try again; keep the smallest value that never pastes stale content.

**Gate.** The developer tests in Terminal, Safari, Xcode, Slack or another
Electron app, and a Claude session, three dictations each. Any stale paste
fails the gate for that delay. The `paste` stage in the A1 log should drop
by about the sleep length.

**Critical path:** yes.

## B5. Snapshot the clipboard on key-down instead of at release

**Evidence.** `Snapshot.capture()` reads every pasteboard item and
representation, up to 4 MB per item, synchronously, before the paste. For a
plain text clipboard that is a few round trips to the pasteboard server;
for rich text or an image it is tens of milliseconds, which is why the cap
exists. Recording lasts seconds, so the read can happen then.

**Change.**

1. `TextOutput` gains `func prepare() async` with a default no-op in a
   protocol extension.
2. `PasteboardOutput.prepare()` captures a snapshot and the current
   `changeCount` into a `prepared` field.
3. `insert` uses the prepared snapshot when `NSPasteboard.general.changeCount`
   still equals the recorded one, otherwise captures fresh. Clear
   `prepared` after use.
4. `DictationCoordinator.hotkeyPressed` calls
   `Task { await output.prepare() }` right after `onEvent(.recordingStarted)`.

Once this is in, the 4 MB cap can rise, because it no longer bounds the
path. Raise it to 64 MB in the same PR so large clipboards are restored.

**Gate.** The `paste` stage with a plain text clipboard and with a
screenshot on the clipboard. Confirm the clipboard is restored after the
paste in both cases.

**Critical path:** yes.

## B6. Main-actor contention during transcription

**Evidence.** `finish` runs on the main actor and resumes there twice on the
path: after `transcribe` returns and after `insert` returns. Meanwhile the
overlay shows a `ProgressView` spinner
(`Sources/Pladder/Overlay/OverlayView.swift:208`), which animates on the
main thread inside a Liquid Glass panel. Each resumption can wait for a
frame to finish.

**Diagnostic first, no code.** The developer switches the overlay style to
"Menu Bar", which draws nothing during transcription, and records ten
dictations; then "Compact" with glass on, ten more. Compare the remainder
of the A1 total after subtracting the four stages. That remainder is the
scheduling cost.

**Change, only if the remainder differs by more than five milliseconds.**
Replace the spinner with a static glyph during `.transcribing`. That is a
removal, which the project prefers, and it takes the animation off the main
thread. Do not move `finish` off the main actor; the review's advice to keep
the state machine in one main-actor file stands.

**Critical path:** yes in effect, though no coordinator code changes.

## Not worth doing on their own

Each of these is under a millisecond and only worth folding into a step
that already touches the file:

- `lastTranscript = transcript` is written before `insert`, which triggers
  an Observation update on the main actor mid-path. Move it after the paste
  when B5 touches `finish`.
- `AXIsProcessTrusted()` runs on every insert. Leave it; a revoked grant
  must fail with the right message.
- A fresh `TdtDecoderState` per utterance in `FluidAudioEngine.transcribe`.
  Tiny allocation; correct as is.

## Order and expected effect

| Step | Type | Expected effect on a 5 s dictation |
|---|---|---|
| A1 | instrumentation | none; makes the rest measurable |
| A2, A3 | correctness | none; removes a lost-dictation bug |
| A4 | architecture and speed | 1 to 5 ms off, more with a large dictionary |
| A5, A6 | architecture | none |
| B2 | experiment | up to about 90 ms off if the idle cost is real |
| B3, B4 | removal | 15 to 25 ms off |
| B1 | new engine | halves the engine share for short dictations, more for long ones |
| B5, B6 | removal | 1 to 20 ms off depending on clipboard and overlay |
