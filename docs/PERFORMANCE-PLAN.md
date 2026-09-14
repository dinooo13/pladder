# Performance plan

A ranked list of changes to the release-to-paste path, each with the code to
write, the test to add, and the measurement that decides whether it stays.
Written so it can be handed to an implementer who has not read the codebase.

The architecture work that preceded this (per-stage timing in the log line,
the pipeline built off the path, the engine captured at press, `EngineLoader`)
is merged. This plan starts from that state.

Every step is one pull request. Do them in order; each assumes the ones
before it have landed and been measured.

## Ground rules for the implementer

Read `CLAUDE.md` first. In addition:

1. **Never** run `pkill -x Pladder`, `killall Pladder`, `bundle.sh --run` or
   `bundle.sh --install` unless the developer asked for it in the same
   message. The developer's own copy of the app is running and in use.
2. **Never** post synthetic key events. The developer records every real-app
   measurement; you prepare the build and the code.
3. `PladderCore` imports Foundation only. AppKit, AVFoundation and FluidAudio
   belong in `PladderSystem`, `PladderAudio` and `PladderEngines`.
4. After every step: `swift build`, then `swift test`. Both must pass before
   the pull request is opened.
5. Every step here touches the code between the coordinator's
   `recordingStopped` and `inserted` events, so the critical-path rule in
   `CLAUDE.md` applies. Run `swift run -c release pladder-cli bench
   bench/fixtures` before and after, in the same session, and put both
   tables in the PR. The bench calls the engine directly and cannot see most
   of these changes; say so in the PR. The decisive numbers are the log lines
   the developer collects.
6. Do not add settings, windows or overlay elements.
7. Keep each pull request to the step described. If something else looks
   wrong, write it down in the PR description and leave it alone.

## How the app measures itself

Every real dictation logs one line:

```
release-to-paste 0.312 s: stop 0.012, engine 0.250, process 0.003, paste 0.014; audio 4.2 s, engine-time 0.241 s
```

Read it with:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```

`stop` is `AudioCapture.stop()`, `engine` is the wall clock around
`transcribe`, `process` is the pipeline, `paste` is `TextOutput.insert`.
`engine-time` is the engine's own measure of its work; the gap between
`engine` and `engine-time` is time the call spent queued on the engine actor.

**Measurement protocol for every step.** The developer dictates the same
sentence ten times per condition, about five seconds each, machine
otherwise quiet, and compares medians per stage. A change is kept when its
stage figure drops and no dictation misbehaves. A change that only moves
time between stages is reverted.

## Where the time goes

For a five-second dictation on the M1 baseline:

| Stage | Estimate | What is happening |
|---|---:|---|
| Engine | 150 to 240 ms | One CoreML encoder pass on the Neural Engine, then the decoder |
| Paste | 12 to 15 ms | Pasteboard read and write, a fixed 10 ms sleep, key event post |
| Capture stop | 5 to 15 ms | Removing the tap, then `AVAudioEngine.pause()` stopping the hardware I/O cycle |
| Processors | under 1 ms | A few regex runs over one sentence |

Two facts shape the ranking:

- **The encoder pass costs the same for any utterance up to 15 s.**
  FluidAudio pads shorter audio with zeros to the model's fixed 15 s input
  (`padAudioIfNeeded(..., targetLength: ASRConstants.maxModelSamples)` in
  `AsrManager+Transcription.swift`). A one-second dictation pays the same
  encoder cost as a twelve-second one. Only the decoder scales with length.
- **The pass is slower from idle.** `docs/BENCHMARKS.md` records the 10 s
  fixture at about 150 ms when runs are back to back and 237 ms after ten
  seconds of idle. The Neural Engine does nothing while the key is held, so
  every real dictation starts from idle and pays the higher figure.

So for the common case, a short dictation, the floor is one warm encoder
pass, roughly 150 ms, and the target is to get everything else out of the
way of it. Only a model with a smaller window goes below that floor; see the
last section.

---

## Step 1. Warm the Neural Engine on key-down

**What it does.** Runs a throwaway transcription of half a second of silence
as soon as the recording starts, so the Neural Engine is already up when the
real call arrives at release. Because of the padding, the warm-up is a full
encoder pass, which is exactly the work the real call will do.

**Where it hooks.** `DictationCoordinator.hotkeyPressed`, which runs only
when the CGEvent tap has matched the configured chord. Ordinary typing never
reaches it. A stray tap of the hotkey that the 300 ms minimum later discards
still triggers a warm-up; that is one wasted pass and harmless.

**Files.** `Sources/PladderCore/DictationCoordinator.swift`,
`Tests/PladderCoreTests/DictationCoordinatorTests.swift`.

**Changes.**

1. Add to the coordinator:

   ```swift
   /// Half a second of silence. Transcribing it at key-down brings the
   /// Neural Engine up from idle while the user is still speaking; every
   /// utterance is padded to the model's full window, so this is the same
   /// encoder pass the real call makes.
   private static let warmupSamples = [Float](repeating: 0, count: 8_000)
   ```

2. In `hotkeyPressed`, directly after `onEvent(.recordingStarted)`:

   ```swift
   if let engine = cycleEngine {
       Task.detached(priority: .utility) {
           _ = try? await engine.transcribe(Self.warmupSamples)
       }
   }
   ```

   The engine actor runs calls one at a time. A release that arrives while
   the warm-up is still running waits for it; that wait is bounded by one
   pass and shows up in the log as `engine` exceeding `engine-time`.

**Test.** Add a `CountingEngine` actor to the test fakes: like `EchoEngine`
but it records the sample count of every `transcribe` call. Test
`keyDownWarmsTheEngine`: press, wait until the engine has one recorded call
of 8,000 samples, release, await `inFlight`, expect a second call with the
capture's sample count and the transcript inserted once. Test
`releaseDuringWarmupStillInserts`: give the counting engine a 200 ms delay,
press, release immediately, await `inFlight`, expect exactly one insert.

**Gate.** Ten five-second dictations with and without. Keep if the median
`engine` stage drops by ten percent or more. Also check `engine` against
`engine-time`: a gap over 20 ms means releases are queuing behind warm-ups.

**If it does not help.** The chip may cool again during the recording. Second
variant, only if the first fails the gate: replace the single detached task
with a `warmupTask` that loops `sleep 2 s, transcribe(warmupSamples)` until
cancelled, and cancel it in `hotkeyReleased` and `cancelRecording`. Same
gate. If that fails too, the idle cost is not where the benchmark suggests,
and Step 6 is the only engine lever.

**Cost.** One encoder pass of Neural Engine power per dictation, spent while
the user is speaking.

## Step 2. Take `AVAudioEngine.pause()` off the path

**What it does today.** `AVAudioEngineCapture.stop()`
(`Sources/PladderAudio/AVAudioEngineCapture.swift:93-113`) removes the tap,
which returns once the last tap callback has finished, drains the captured
samples, and then calls `engine.pause()`. Pausing stops CoreAudio's hardware
I/O cycle and blocks until the current device buffer completes, typically
several milliseconds. The pause exists only to turn off the orange
microphone indicator; the samples are complete before it starts.

**Change.** Return the audio first, pause afterwards on the actor:

```swift
public func stop() async -> CapturedAudio {
    guard isRecording else { return CapturedAudio(samples: []) }
    isRecording = false

    engine.inputNode.removeTap(onBus: 0)
    var samples = carriedSamples
    carriedSamples.removeAll(keepingCapacity: false)
    if let processor {
        samples.append(contentsOf: processor.drain())
    }
    processor = nil

    levelContinuation?.finish()
    levelContinuation = nil

    // Off the release-to-paste path: the microphone indicator going off a
    // few milliseconds later is invisible, the pause blocking here is not.
    Task { [weak self] in await self?.pauseIfIdle() }
    return CapturedAudio(samples: samples)
}

/// Pauses the engine unless a new recording started while the pause was
/// queued. `startEngineIfNeeded` skips `start()` when the engine is still
/// running, so a back-to-back recording stays live either way.
private func pauseIfIdle() {
    guard !isRecording else { return }
    engine.pause()
}
```

**Test.** `PladderAudio` has no hardware tests, and none should be added.
Review the change against the comment block at the top of the file.

**Gate.** The `stop` stage. Keep if it drops. The developer also confirms
the microphone indicator still goes off after every dictation, including two
dictations in quick succession.

## Step 3. Remove the 10 ms sleep before Cmd+V

**What it does today.** `PasteboardOutput.insert`
(`Sources/PladderSystem/PasteboardOutput.swift:86`) writes the transcript to
the pasteboard, sleeps `propagationDelay` (10 ms, line 42), then posts
Cmd+V. The sleep guards against the target app reading the pasteboard before
the write has landed. But the write is a synchronous call to the pasteboard
server, so it has landed when the call returns, and the key event still has
to travel through the window server to the target app after that. The sleep
is insurance against a race the ordering already prevents, and `Task.sleep`
adds scheduling slack on top of the ten.

**Change.** Make the delay an initialiser parameter defaulting to zero, and
skip the sleep entirely when it is zero:

```swift
public init(
    restoreDelay: Duration = .milliseconds(400),
    submitDelay: Duration = .milliseconds(50),
    propagationDelay: Duration = .zero
)
...
if propagationDelay > .zero {
    try await Task.sleep(for: propagationDelay)
}
```

Update the comment on the property to say why zero is the default and what
to try if an app pastes stale content.

**Test.** None; the behaviour is in the target app.

**Gate.** The developer pastes three dictations each into Terminal, Safari,
Xcode, an Electron app such as Slack, and a Claude session. Any stale paste,
meaning the old clipboard content appears instead of the transcript, fails
the gate for that delay; try 2 ms next and keep the smallest value that never
fails. The `paste` stage should drop by about the sleep length.

## Step 4. Snapshot the clipboard on key-down

**What it does today.** Before every paste, `Snapshot.capture()` reads every
pasteboard item and every representation of it, up to 4 MB per item,
synchronously, on the path. For a plain text clipboard that is a few round
trips to the pasteboard server; for rich text or an image it is tens of
milliseconds, which is why the 4 MB cap exists. Recording lasts seconds, so
the read can happen then.

**Files.** `Sources/PladderCore/Protocols/TextOutput.swift`,
`Sources/PladderSystem/PasteboardOutput.swift`,
`Sources/PladderCore/DictationCoordinator.swift`, tests.

**Changes.**

1. `TextOutput` gains `func prepare() async`, with a no-op default in a
   protocol extension so `FakeOutput` and any other conformer keep
   compiling.
2. `PasteboardOutput.prepare()` captures a snapshot and
   `NSPasteboard.general.changeCount` into a `prepared: (Snapshot, Int)?`
   field.
3. `insert` uses the prepared snapshot when the current `changeCount` still
   equals the recorded one, otherwise captures fresh as today. Clear
   `prepared` after use. The existing carry-forward logic for back-to-back
   inserts is unchanged and takes precedence.
4. In `hotkeyPressed`, next to the warm-up from Step 1:
   `Task { await output.prepare() }`.
5. Raise `maximumItemBytes` to 64 MB in the same PR: it no longer bounds the
   path, so large clipboards can be restored instead of dropped. Update its
   comment.

**Test.** Give `FakeOutput` a `prepareCount`. Test
`keyDownPreparesTheOutput`: press, expect `prepareCount == 1` before release.

**Gate.** The `paste` stage with a plain text clipboard and with a
screenshot on the clipboard. Confirm the clipboard is restored after the
paste in both cases, and that copying something during a recording still
wins over the snapshot.

## Step 5. Check main-actor contention during transcription

**What happens today.** `finish` runs on the main actor and resumes there
twice on the path: after `transcribe` returns and after `insert` returns.
Meanwhile the overlay shows a `ProgressView` spinner
(`Sources/Pladder/Overlay/OverlayView.swift:208`) animating on the main
thread inside a Liquid Glass panel. Each resumption can wait for a frame.

**Diagnostic first, no code.** The developer sets the overlay style to
Menu Bar, which draws nothing during transcription, records ten dictations,
then sets Compact with glass on and records ten more. Subtract the four
stages from the total on each line; the remainder is scheduling cost.
Compare the medians.

**Change, only if the remainder differs by more than five milliseconds.**
Replace the spinner with a static glyph during `.transcribing`. That is a
removal, which the project prefers. Do not move `finish` off the main actor.

## Step 6. Long dictations: transcribe while the user is still speaking

Everything above helps every dictation. This step helps only dictations
longer than about 13 seconds, because of how the sliding window works. Do
it only if the developer dictates long passages often enough to care.

**What happens today.** At release the whole recording is padded, turned
into a mel spectrogram, encoded in 15 s windows with 2 s overlap, up to four
at once, and decoded. Sixty seconds of audio costs five window passes,
about 560 ms on the M1.

**What FluidAudio offers.** `SlidingWindowAsrManager`
(`.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/`)
runs the same downloaded TDT models on audio as it arrives. Each time its
buffer holds an 11 s chunk plus 2 s of context on either side it runs one
encoder pass and confirms that chunk's text. `finish()` flushes whatever is
left after the last confirmed chunk in one more pass, without right
context, and merges the tokens. `startStreaming(source:)` does not open the
microphone; the source is a label, and audio is pushed with
`streamAudio(AVAudioPCMBuffer)`. It takes the already-loaded `AsrModels`
via `loadModels(_:)`, so there is no second download.

**What it gains.** The first chunk needs 13 s of audio before it runs, so a
short dictation reaches release with nothing confirmed and the flush is one
full padded pass, the same as today. For 60 s, five passes become one flush
pass: roughly 560 ms down to 150 to 240 ms. In between, the saving grows
with every 11 s chunk completed before release.

**Design.** A second engine behind a streaming protocol, so the batch engine
is untouched and reverting is one registry line.

1. `PladderCore`, in `Protocols/TranscriptionEngine.swift`:

   ```swift
   /// An engine that consumes audio while it is being recorded, so that
   /// only the tail remains to transcribe at release.
   public protocol StreamingTranscriptionEngine: TranscriptionEngine {
       func beginUtterance() async throws
       /// 16 kHz mono samples captured since the previous call.
       func feed(_ samples: [Float]) async
       /// Feeds the last samples and returns the transcript for the whole utterance.
       func endUtterance(_ tail: [Float]) async throws -> Transcript
       func abandonUtterance() async
   }
   ```

2. `AudioCapture` gains `func drain() async -> [Float]`: the samples since
   `start()` or the previous `drain()`, cleared on return; `stop()` then
   returns only what came after the last drain. `AVAudioEngineCapture`
   implements it with the existing `TapProcessor.drain()`. `FakeCapture`
   returns an empty array unless a test sets samples.

3. `PladderEngines`, new `FluidAudioStreamingEngine.swift`: an actor
   conforming to `StreamingTranscriptionEngine`. `load()` downloads via
   `AsrModels.downloadAndLoad` as `FluidAudioEngine` does, builds a
   `SlidingWindowAsrManager(config: .default)` and calls `loadModels(models)`.
   `beginUtterance` calls `startStreaming`. `feed` wraps the samples in a
   16 kHz mono `AVAudioPCMBuffer` and calls `streamAudio`. `endUtterance`
   feeds the tail, times `finish()`, and returns a `Transcript` whose
   `processingTime` is that duration and whose `audioDuration` is the total
   fed. `abandonUtterance` calls `cancel()`. `transcribe(_:)` is begin,
   feed, end, so the CLI and tests can still call it. Register it in
   `AppModel` as "Parakeet TDT v3 (streaming)", not as the first entry.

4. `DictationCoordinator`: when `cycleEngine is any StreamingTranscriptionEngine`,
   `hotkeyPressed` calls `beginUtterance()` and starts a `feedTask` that
   loops: sleep one second, `capture.drain()`, `engine.feed(chunk)`, adding
   to `fedSampleCount`. `hotkeyReleased` cancels the task, then
   `capture.stop()` gives the tail, then `endUtterance(tail.samples)`. The
   minimum-duration check uses `fedSampleCount` plus the tail.
   `cancelRecording` cancels the task and calls `abandonUtterance()`. The
   warm-up from Step 1 is skipped for streaming engines; the feed keeps the
   Neural Engine busy.

5. `PladderCLI`: a `--engine streaming` flag. For the streaming engine the
   bench pushes each fixture in one-second chunks paced at real time, so
   windows are processed as they would be in the app, then times
   `endUtterance` alone and reports it as the engine time, with word error
   rate as today. Pacing takes as long as the audio, so run only the 10 s,
   30 s and 60 s fixtures.

**Gate.** From the extended bench on the M1: `endUtterance` under half the
batch engine time on the 30 s and 60 s fixtures, and word error rate within
one point of the batch engine on all three. Then ten real long dictations
per engine. Only if both pass does the streaming engine become the default
for new installs. Existing settings keep their engine ID.

**Risks.** FluidAudio's own comments warn that v3 in streaming windows can
emit wrong-script tokens (their issue 512) and that seams can drop or
duplicate words. The word error rate gate exists for this. The encoder runs
while the key is held, which costs power. This is the largest step in the
plan; keep it behind the protocol.

**Result.** Landed as the second registry entry. Time gate met at 60 s and
narrowly missed at 30 s; accuracy equal to batch up to 30 s and one to six
points worse beyond, growing with the number of seams (table in Step 8).
Batch stays the default; streaming is selectable. Step 8 is the follow-up
that keeps the latency and removes the accuracy cost.

## Step 7. Long dictations: the seam-gap repair pass

Independent of Step 6 and much smaller. `FluidAudioEngine` builds its
manager with `AsrManager(config: .default)`
(`Sources/PladderEngines/FluidAudioEngine.swift:42`). The default
`ASRConfig` has `seamGapRepair: true`, a post-merge pass that probes for
content dropped at chunk seams. It runs only when audio is chunked, so only
for dictations over 15 s, and it costs time on that path.

**Change.** `AsrManager(config: ASRConfig(seamGapRepair: false))`.

**Gate.** This is the one step the CLI bench sees directly. Compare the 30 s,
60 s and 2 m fixtures before and after: keep if engine time drops by ten
percent or more and word error rate rises by less than half a point on all
three. The 10 s fixture must not move.

## Step 8. Incremental batch: run the batch engine's windows while the user speaks

**Why.** Step 6 measured, same session, batch versus the sliding-window
streaming engine with exact tail padding:

| Fixture | Batch time | Streaming time | Batch WER | Streaming WER |
|---|---:|---:|---:|---:|
| 10 s | 0.258 s | 0.187 s | 0.0% | 0.0% |
| 30 s | 0.399 s | 0.245 s | 0.0% | 0.0% |
| 60 s | 0.590 s | 0.198 s | 1.4% | 2.8% |
| 2 m | 0.938 s | 0.192 s | 0.9% | 4.8% |
| 5 m | 2.022 s | 0.192 s | 0.6% | 7.2% |
| 10 m | 3.777 s | 0.189 s | 0.6% | 5.0% |

Streaming is flat in time and loses accuracy on seams. Batch is flat in
accuracy and grows in time. The two engines run the same CoreML models and
the same `transcribeChunk` call; they differ only in how windows are laid
out and merged. `SlidingWindowAsrManager` carries the LSTM decoder state
across windows, cuts every 11 s regardless of speech, and removes
duplicates by matching token sequences. `ChunkProcessor`, the batch path,
starts every window from a fresh decoder state, aligns window starts to
silence, decodes a suppressed prefix of real audio for context, and merges
by timestamp. Batch's 0.6% at ten minutes shows that scheme works.

`ChunkProcessor` is stateless per window, and its start rule for window
*n+1* searches at most a few seconds around the nominal stride and is
capped before window *n* ends, so it reads only audio that already exists
when window *n* can run. Every window but the last can therefore run while
the user is still speaking, and the merge at release sees exactly the
inputs batch would have seen. The theory to test: **identical text to the
batch engine, one window at release, so under 250 ms at every length.**

It costs the chip nothing extra: the same passes batch would run at
release run earlier instead. The sliding-window engine spent extra passes
on overlap; this does not. (The 10 s row above is not a streaming win: below
15 s both engines run the same single padded pass, and the gap is warmth.)

**Why a fork.** `ChunkProcessor`, `transcribeChunk`, `mergeChunks` and
`processTranscriptionResult` are all `internal`. FluidAudio is Apache 2.0.
Keep the fork diff to one new file plus the smallest refactor that lets it
share code, so it rebases onto upstream releases and can be offered
upstream.

**Fork setup.**

1. Fork `FluidInference/FluidAudio` on GitHub. Branch `incremental-chunks`
   from the revision `Package.resolved` pins today (`4dbf4f9`, the 0.15.6
   line). Do not branch from a newer upstream in the same step; that mixes
   a library upgrade into the measurement.
2. Clone it next to this repository. While the experiment runs, point
   `Package.swift` at it with `.package(path: "../FluidAudio")`. Once the
   gate passes, switch to `.package(url: <fork>, branch:
   "incremental-chunks")` or a revision pin. A path dependency must never
   reach `main`.
3. `swift test` in the fork must pass before and after every change there.
   FluidAudio's own tests use `...ForTesting` hooks on `ChunkProcessor`
   (`chunkLayoutForTesting`, `chunkStartDecisionsForTesting`,
   `mergeTokenWindowsForTesting`); keep them compiling.

**Fork changes.** All in `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/`.

1. In `ChunkProcessor.swift`, lift two pieces of `process(using:...)` into
   helpers that `process` then calls, so the incremental path shares them
   rather than copying 1,500 lines:

   - The per-window plan. Given `chunkIndex`, `chunkDecision`,
     `totalSamples`, `speechEnd` and the layout, it returns what the loop
     body computes today: `contextSamples`, `contextStart`, `audioEnd`,
     `chunkStartOffset`, `emitTokensAfterFrame`, `isLastChunk`, or nil when
     the loop would `break` (empty window, pure-silence tail).
   - The merge tail. Given `[[TokenWindow]]` in order, it does what the code
     after the task group does: `spliceSafeTokenIds`,
     `caseVariantCanonicalIds`, pairwise `mergeChunks`,
     `enforceMonotonicTimestamps`, `collapseSeamWordDuplicates`, then the
     seam-gap repair pass when `manager.seamGapRepair` is on, then
     `processTranscriptionResult`.

   Also split `silenceAlignedChunkStarts` so its loop body is a
   `nextSilenceAlignedStart(after previousStart:)` that the existing
   function calls in a loop. That is the piece the incremental processor
   calls one window at a time. `process` must produce byte-identical
   results before and after this refactor; the fork's existing tests plus
   the identity gate below check that.

2. New file `IncrementalChunkProcessor.swift`:

   ```swift
   /// `ChunkProcessor` for audio that arrives over time. Windows run as
   /// soon as the audio they need exists; `finish()` runs the last window
   /// and the same merge `ChunkProcessor.process` runs, so the text is
   /// identical to a batch transcription of the same samples.
   public actor IncrementalChunkProcessor {
       public init(manager: AsrManager, language: Language? = nil) async throws
       /// Appends samples and runs every window whose end is now covered.
       public func append(_ samples: [Float]) async throws
       /// Runs the final window, merges, and returns the result.
       public func finish() async throws -> ASRResult
       public func cancel()
   }
   ```

   Internals:

   - At init read `melChunkContext`, `modelVersion`, `decoderLayerCount`,
     `vocabulary` and the layout once, as `process` does. Throw if
     `dualDecodeArbitration` is on; that path is not supported and Pladder
     never enables it.
   - Hold a growing `[Float]` behind a `GrowingSampleSource:
     AudioSampleSource` whose `sampleCount` is the audio so far, so the
     silence search and `readSamples` work unchanged.
   - Window *n* is run as a non-last window only when
     `available > chunkStart + visibleChunkSamples` (strictly greater: batch
     marks a window last when `candidateEnd >= totalSamples`, and the
     final total will be at least `available`). Windows run one at a time
     on the actor with a fresh `TdtDecoderState`, through
     `ChunkProcessor.transcribeChunk`, and their `[TokenWindow]` is stored
     by index. No worker pool; one window at a time is the point.
   - After each window, decide the next start with
     `nextSilenceAlignedStart` (or `chunkStart += strideSamples` where
     `process` falls back to that) and wait for more audio.
   - `finish()`: with the total now known, compute `speechEndSamples()`,
     plan the last window exactly as `process` does (including
     `lastChunkWarmupSamples`, which may pull its start back to fill the
     window with real audio), run it with `isLastChunk: true`, then the
     shared merge tail.

   Nothing else in the module becomes public.

**Pladder changes.**

1. `Sources/PladderEngines/FluidAudioIncrementalEngine.swift`, an actor
   conforming to `StreamingTranscriptionEngine`, engine ID
   `parakeet-tdt-v3-incremental`, display name "Parakeet TDT v3
   (incremental)". `load()` is `FluidAudioEngine.load()`: one `AsrManager`
   with `seamGapRepair: false`. `beginUtterance` creates an
   `IncrementalChunkProcessor(manager:)`. `feed` is `append`. `endUtterance`
   appends the tail, times `finish()`, and returns a `Transcript` with that
   duration as `processingTime`. `warmPass` transcribes the half second of
   silence through the manager, the same pass the batch engine warms with.
   `abandonUtterance` cancels. No hybrid path: below 15 s `finish()` is one
   window, which is what batch does.
2. Register it in `AppModel` after the batch engine.
3. `PladderCLI`: `--engine` takes `streaming` or `incremental` and the paced
   bench picks the engine by name. For every fixture the paced bench also
   runs the batch engine once and prints `identical: yes` or the first
   differing word with its position. The identity gate needs that line.

**Test.** In the fork, one test that feeds synthetic audio to
`IncrementalChunkProcessor` in one-second pieces and to
`ChunkProcessor.process` whole, and expects identical tokens. Follow
FluidAudio's pattern for tests that need models and skip when they are
absent. In Pladder the coordinator's streaming branches are already covered
with a fake engine; the new engine adds no coordinator behaviour.

**Gate.** Three conditions, in this order.

1. **Identity.** On all six fixtures the incremental text equals the batch
   text, byte for byte, before any processor runs. A difference is a bug in
   the fork, never a tuning matter. Do not proceed on "close enough".
2. **Time.** `endUtterance` median under 250 ms on every fixture in the
   paced bench, then in the app: ten 5 s and ten 60 s dictations with a
   median `engine` stage under 250 ms in the log lines.
3. **Cold releases.** The stride is about 13 s, longer than the idle gap
   that produced the cold penalty in `docs/BENCHMARKS.md`. If the 60 s
   app dictations show `engine` near 240 ms with `engine-time` close behind,
   the last window ran cold: add the periodic warm pass from Step 1's
   second variant to the feed loop and measure again. Only then.

When all three pass: the incremental engine becomes the default for new
installs, batch stays selectable for one release, and the sliding-window
engine from Step 6 is deleted along with its hybrid path and the
`shortUtteranceSamples` threshold. If identity fails and cannot be fixed
inside the fork's own seam logic, stop: the theory was wrong, and the
sliding-window engine stays as the opt-in long-dictation option.

**Risks.**

- The refactor touches the code that gives batch its 0.6%. Every change
  there is gated by the fork's tests and by identity against the
  unmodified upstream revision, which the CLI can run by switching
  `Package.swift` back for one build.
- FluidAudio moves quickly. Each upstream release means rebasing the fork.
  The small diff and an upstream pull request are the mitigations.
- A release that lands while a window is running queues the last window
  behind it: one extra pass, bounded, roughly one dictation in a hundred.
- The buffer holds the whole utterance in memory, about 8 MB at the 120 s
  cap. Batch already does the same.

## Below the floor: a model with a smaller window

With Parakeet TDT, a dictation can never be faster than one encoder pass
over a padded 15 s window, roughly 150 ms warm on the M1. Getting under that
needs a model whose window is smaller.

FluidAudio ships Parakeet Unified streaming variants
(`StreamingModelVariant.parakeetUnified320ms` and siblings, in
`ASR/Parakeet/Streaming/ParakeetModelVariant.swift`). They re-encode a
window of about six seconds per chunk, with chunks as short as 160 ms, and
FluidAudio's notes say the streamed output matches the offline model
closely. `finish()` on such an engine flushes a fraction of a second of
audio. This is a different model repository, so a second download of
several hundred megabytes, and a different accuracy profile.

If Step 1 and Step 6 have landed and the developer still wants more, add
this as a third engine behind the same `StreamingTranscriptionEngine`
protocol, benchmark it with the same `--engine` flag, and gate it on the
same word error rate rule. Do not start it before then: it inherits the
protocol, the capture drain and the paced bench from Step 6.

## Order and expected effect

| Step | Applies to | Expected effect on a 5 s dictation |
|---|---|---|
| 1 Warm-up on key-down | every dictation | up to about 90 ms off the engine stage |
| 2 Pause off the path | every dictation | 5 to 15 ms off the stop stage |
| 3 Sleep before Cmd+V | every dictation | about 10 ms off the paste stage |
| 4 Clipboard snapshot on key-down | every dictation | 1 to 5 ms, more with a rich clipboard |
| 5 Main-actor contention | every dictation | 0 to 16 ms, measured before touching |
| 6 Transcribe while speaking | over 13 s only | none for 5 s; 560 ms to about 200 ms at 60 s |
| 7 Seam-gap repair off | over 15 s only | none for 5 s; measured by the bench |
| 8 Incremental batch | over 15 s only | none for 5 s; batch text at one window, under 250 ms at any length |
| Smaller-window model | every dictation | below the 150 ms floor; a second download |
