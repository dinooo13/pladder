# Performance

Why Pladder is fast. This file explains the design.
[BENCHMARKS.md](BENCHMARKS.md) explains how the numbers are taken, and
[PERFORMANCE-PLAN.md](PERFORMANCE-PLAN.md) has the step-by-step engineering
behind each change, with the code and the gate that decided whether it
stayed.

## The only number

Release-to-paste: the time between the hotkey coming up and the text
appearing at the cursor. In the code it is everything between the
coordinator's `recordingStopped` and `inserted` events, and it has four
stages.

| Stage | What it is |
|---|---|
| `stop` | `AudioCapture.stop()`: remove the tap, collect the samples |
| `engine` | `TranscriptionEngine.transcribe`, or `endUtterance` |
| `process` | The processor pipeline |
| `paste` | `TextOutput.insert`: write the pasteboard, post Cmd+V |

Nothing else counts. Model load happens at launch, the user is not waiting
for it. Time spent while the key is held is free, because the user is still
speaking. Every real dictation logs one line with the total and all four
stages, so the number is not a benchmark artefact; see the end of
[BENCHMARKS.md](BENCHMARKS.md) for how to read it.

The rule that follows from this is in [CLAUDE.md](../CLAUDE.md): nothing
lands on that path without a before-and-after benchmark.

## The floor

Parakeet TDT v3 runs on the Neural Engine through FluidAudio. The model has
a fixed 15 s input window and FluidAudio zero-pads every utterance to it. So
one encoder pass costs the same for a one-second utterance as for a
twelve-second one. Only the decoder scales with length.

On an M1, a warm pass over a short utterance, encoder and decoder together,
is about 0.151 s. That is the floor for a short dictation. Everything else
on the path is a rounding error next to it: the capture stop and the paste
were each estimated at 5 to 15 ms before the work below trimmed them, and
the processors, which are regex passes over one sentence, run in under a
millisecond. Going below the floor needs a different model with a smaller
window, not better engineering around this one.

So the work is not to make the pass faster. It is to make sure the pass is
the only thing on the path, and that it is warm when it starts.

## What was taken off the path

Everything that does not have to happen between release and paste happens
before it, at key-down, or after it.

- **The engine loads at launch** and stays resident. The first dictation of
  a session pays what the hundredth pays.
- **The processor pipeline is rebuilt when settings change**, never per
  dictation.
- **The Neural Engine is warmed while the key is held**, with half a second
  of silence, once at key-down and every two seconds after. Because of the
  padding, that is the same encoder pass the real call will make. One pass
  at key-down is not enough for a long dictation: the chip goes idle again
  while the user keeps speaking.
- **The clipboard is snapshotted at key-down.** Reading every representation
  of a rich clipboard takes tens of milliseconds, and the recording lasts
  seconds, so it happens then.
- **The microphone pause happens after the samples are returned.**
  `AVAudioEngine.pause()` blocks until the current device buffer completes.
  The samples are already complete when it starts, so the orange indicator
  goes off a few milliseconds later and nobody waits for it.
- **The old clipboard is restored after the paste**, not before it.
- **The Return for the send key is posted from a detached task**, 50 ms
  after Cmd+V.

One thing was deleted rather than moved. There used to be a 10 ms sleep
between writing the pasteboard and posting Cmd+V, insurance against the
target app reading a stale pasteboard. The pasteboard write is a
synchronous call to the pasteboard server, so it has landed when the call
returns, and the key event still has to cross the window server after that.
The sleep guarded a race the ordering already prevents.

An earlier version also ran an Apple Intelligence cleanup step on the path.
It was removed. Nobody had measured what it cost.

## Why length used to cost time

Audio longer than one encoder window is laid out in about 15 s windows with
2 s of overlap. The default engine does that layout at release and decodes
every window then, so the cost grows with the recording: 0.520 s for a
minute, 3.665 s for ten minutes. That is fine for a sentence and poor for a
monologue.

The fix is not a different model or a different window scheme. It is doing
the same work earlier. Three properties of the batch layout make that
possible:

1. Windows do not depend on each other. Each starts from a fresh decoder
   state.
2. A window's start is chosen from audio that ends before the previous
   window does, so the decision never needs audio that has not arrived.
3. The merge is by timestamp over the finished windows.

The incremental engine runs those same windows while the user is still
speaking. At release only the final window and the merge remain, which is
one pass at any length. The chip does no extra work; the passes that batch
would have run at release run earlier instead.

The text it produces is byte-identical to the default engine's on every
fixture, which is the point. Flat latency at no cost in accuracy. The paced
bench checks that identity on every run and treats any difference as a bug,
not a tuning matter.

**The incremental engine is opt-in today.** It is selected in Settings and
it is not the default. It needs confirmation from real dictations, not just
fixtures, before that changes.

## The measurements

Apple M1, macOS 26.6.2, one session, load average 2.12.

```sh
swift run -c release pladder-cli bench bench/fixtures \
  --engine incremental --all --runs 3 --pause 10
```

| Fixture | Audio | Batch (default) | Incremental (opt-in) | Identical text | WER, both |
|---|---:|---:|---:|---|---:|
| 10s | 9.7 s | 0.206 s | 0.257 s | yes | 0.0 % |
| 30s | 31.8 s | 0.416 s | 0.252 s | yes | 0.0 % |
| 60s | 60.8 s | 0.520 s | 0.278 s | yes | 1.4 % |
| 2m | 125.1 s | 0.941 s | 0.254 s | yes | 0.9 % |
| 5m | 315.6 s | 2.007 s | 0.275 s | yes | 0.6 % |
| 10m | 631.4 s | 3.665 s | 0.323 s | yes | 0.6 % |

Each fixture is pushed to the incremental engine in one-second chunks paced
at real time, and only `endUtterance` is timed, which is what remains on the
release-to-paste path. The batch column is the same samples through the
default engine, whole, clock-timed, after the same ten seconds of idle.

Read the columns with their basis in mind. The batch column is one run per
fixture. The incremental column is the median of two timed runs after a
discarded warm-up. At 10 s both engines execute the same code, so the
difference on that row is measurement noise, not a regression. The word
error rate is against synthetic speech and is a regression check, not an
accuracy claim; [BENCHMARKS.md](BENCHMARKS.md) says why.

## What is still slow

**The cold pass.** Same 10 s fixture, same engine, identical code: 0.151 s
when runs are back to back, 0.265 s after ten seconds of idle. The
difference, 0.114 s, is larger than the stop, process and paste stages put
together on those estimates. A real dictation always starts from idle,
because the Neural Engine does nothing while the user thinks about what to
say. That is what the key-down warm pass is for, and it is why the warm-up
is a full padded pass rather than a token call.

**The last window of a long recording used to run cold.** The incremental
engine's stride is about 13 s, so a user who stops speaking shortly after a
window completes left the final window starting from an idle chip. A real
68 s dictation measured 0.252 s of engine time, which is the cold figure,
not the warm one. The warm pass now repeats every two seconds for as long
as the key is held, which is what the numbers in the table above do not yet
include: they come from the paced bench, which never warms.

The repeat is not free in either direction. A release landing inside a warm
pass waits for it, because a CoreML call already running cannot be
cancelled, so roughly one dictation in fourteen pays up to one extra pass.
The interval is the dial: longer means more dictations start cold, shorter
means more land on a pass in flight. Two seconds is a starting point, not a
measured optimum.

**The floor itself.** A one-word dictation pays a full 15 s padded encoder
pass. No amount of work around the model changes that. FluidAudio ships
Parakeet Unified streaming variants with a window of about six seconds and
chunks as short as 160 ms, which would move the floor down, at the cost of
a second several-hundred-megabyte download and a different accuracy
profile. It is not in the app.

## Reading a regression

If the release-to-paste log line grows, subtract the four stages from the
total. The remainder is actor scheduling: the coordinator resumes on the
main actor between stages. A growing remainder means something new is
contending with the main actor, not that the engine got slower. The
engine's own `processingTime` is logged as `engine-time` beside the stages.

A gap between `engine` and `engine-time` has two possible causes, and they
are worth telling apart. With the default engine it means the call waited
on the engine actor, usually behind a key-down warm pass. With a streaming
or incremental engine it also covers the tail being fed at release, which
the engine's own timer starts after, so a gap there is not necessarily
contention.

The stages are logged with `privacy: .public`. Without that marker the
system redacts the interpolated string and the line reads `<private>`
where the four numbers should be, which is how it behaved until this was
fixed.
