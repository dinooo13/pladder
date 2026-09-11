# Benchmarks

How SpeakUp's speed is measured, and the baseline to compare against. The
benchmark is run by hand before and after any change on the release-to-paste
path (see [CLAUDE.md](../CLAUDE.md)). It is not part of the test suite: a
benchmark that fails on noise gets ignored.

## What is measured

- **Engine time and realtime factor** per fixture: wall clock around
  `engine.transcribe`, the same call the coordinator makes. Realtime factor is
  audio length divided by engine time, so 30x means a minute of speech in two
  seconds.
- **Word error rate** per fixture against the known script, so a change that
  is faster but worse is caught. Case and punctuation are ignored; only the
  words count.
- **Model load time** (cold start, one measurement per process, the time the
  app spends before the hotkey is enabled) and **physical memory footprint**
  after load, the number Activity Monitor shows.
- **Release-to-paste time** per dictation, in the app, between the
  `recordingStopped` and `inserted` coordinator events. Logged, not
  benchmarked: it is the number the user feels and includes capture stop,
  engine, processors and paste. See the end of this file for how to read it.

## Fixtures

`scripts/make-fixtures.sh` synthesises speech with the macOS `say` command
(voice Samantha, 175 words per minute) from a fixed script of plain prose, at
six lengths, as 16 kHz mono Float32 WAV with the spoken text beside each file.
They are generated on demand into `bench/fixtures` (gitignored) and never
committed, so there is no personal audio in the repo and anyone can regenerate
them.

| Fixture | Target | Why |
|---|---|---|
| 10s | 10 s | One encoder pass. FluidAudio's encoder window is 15 s. |
| 30s | 30 s | Chunked path: 15 s windows with 2 s overlap. |
| 60s | 60 s | Chunked path. |
| 2m | 2 min | The app's recording cap. |
| 5m | 5 min | Beyond the cap, CLI only. Bounds the extreme case. |
| 10m | 10 min | Beyond the cap, CLI only. Heats the chip, so it runs last. |

30 s through 10 min show whether engine time grows linearly with chunk count
and whether accuracy degrades at chunk seams, which FluidAudio's own notes
flag for the v3 multilingual model.

Synthetic speech is cleaner than a real microphone, so the word error rate is
a regression check, not an accuracy claim. Each fixture is a whole number of
sentences, so actual lengths differ from the targets by a few percent; the
benchmark reports the actual length.

## Procedure

1. Close other heavy work and check that `uptime` shows a low load average.
   Numbers jitter with thermal state and other load.
2. Generate the fixtures once: `./scripts/make-fixtures.sh`
3. Run: `swift run -c release speakup-cli bench bench/fixtures`
4. Five runs per fixture. The first (CoreML warm-up) is discarded and the
   median of the rest is reported. Fixtures run shortest to longest.
5. A difference under roughly ten percent is noise. If a change lands near
   that line, run again.

Baselines from other machines are not comparable to the one below. Add a
separate table with chip, macOS version and model version.

## Baseline

Reference machine: Apple M1, 16 GB, macOS 26.6.2 (25G83), FluidAudio 0.15.6,
model `parakeet-tdt-0.6b-v3` (CoreML). Recorded 2026-09-11. The M1 is the
least powerful chip SpeakUp supports: if it is fast enough here, it is fast
enough everywhere.

| Measurement | Value |
|---|---:|
| Model load, fresh process | 0.32 s |
| Physical footprint after load | 98 MB |

The load time is with CoreML's compiled-model cache warm. The very first load
after the download, or after a macOS update invalidates the cache, compiles
the models and takes far longer; that is a one-time cost and not what this
number tracks. The weights run on the Neural Engine and are held outside the
process, so the footprint understates total memory use.

| Fixture | Audio | Engine (median) | Realtime | WER |
|---|---:|---:|---:|---:|
| 10s | 9.7 s | 0.152 s | 64x | 0.0 % |
| 30s | 31.8 s | 0.344 s | 92x | 0.0 % |
| 60s | 60.8 s | 0.512 s | 119x | 1.4 % |
| 2m | 125.1 s | 0.868 s | 144x | 0.9 % |
| 5m | 315.6 s | 1.959 s | 161x | 0.6 % |
| 10m | 631.4 s | 3.739 s | 169x | 0.6 % |

Engine time grows close to linearly with audio length; the realtime factor
rises because the fixed cost per call is amortised.

The table is the first of two passes. The first ran with a load average of
about 2.5 from other work on the machine; the second started at 1.1 and rose
to 4.6 while it ran. The second pass gave medians of 0.150, 0.361, 0.495,
0.977, 1.955 and 3.792 s with identical word error rates. Everything but the
2 min fixture agrees within three percent, and that one had a single
disturbed run (1.16 s against about 0.9 s for the others). That is the noise
floor to keep in mind: a change has to move a number by more than that to
mean anything.

The 60 s fixture's errors are two
mishearings, "flowers" heard as "flours" and "rye loaf" merged into one word.
The sentence with "flowers" is transcribed correctly in the 30 s fixture,
where it does not sit near a window boundary, which is the kind of seam
effect the longer fixtures exist to expose.

## Reading the app's release-to-paste log

Every dictation logs one line with the total release-to-paste time, the audio
length and the engine's share of it:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.speakup.app"'
```

The difference between the total and the engine time is capture stop,
processors and paste. If that gap grows, something new is on the path.
