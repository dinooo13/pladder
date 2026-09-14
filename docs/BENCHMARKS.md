# Benchmarks

How Pladder's speed is measured, and the baseline to compare against. The
benchmark is run by hand before and after any change on the release-to-paste
path (see [CLAUDE.md](../CLAUDE.md)). It is not part of the test suite: a
benchmark that fails on noise gets ignored. For why the numbers look the way
they do, see [PERFORMANCE.md](PERFORMANCE.md).

## What is measured

- **Engine time and realtime factor** per fixture: wall clock around
  `engine.transcribe`, the same call the coordinator makes. Realtime factor is
  audio length divided by engine time, so 30x means a minute of speech in two
  seconds.
- **Word error rate** per fixture against the known script, so a change that
  is faster but worse is caught. Case and punctuation are ignored; only the
  words count. The calculation lives in the `PladderBench` target, which
  only the CLI links; the app carries nothing benchmark-related.
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
| 30s | 30 s | Chunked path: 15 s windows with 2 s overlap, up to four decoded concurrently. |
| 60s | 60 s | Chunked path. |
| 2m | 2 min | The app's recording cap. |
| 5m | 5 min | Beyond the cap, CLI only. Bounds the extreme case. |
| 10m | 10 min | Beyond the cap, CLI only. Heats the chip, so it runs last. |

30 s through 10 min show whether engine time grows linearly with chunk count
and whether accuracy degrades at chunk seams, which FluidAudio's own notes
flag for the v3 multilingual model. The concurrency is FluidAudio's default
and the same one the app uses, so the realtime factor rises with length: a
single window runs alone, long audio keeps four workers busy.

Synthetic speech is cleaner than a real microphone, so the word error rate is
a regression check, not an accuracy claim. Each fixture is a whole number of
sentences, so actual lengths differ from the targets by a few percent; the
benchmark reports the actual length.

## Procedure

1. Close other heavy work and check that `uptime` shows a low load average.
   Numbers jitter with thermal state and other load.
2. Generate the fixtures once: `./scripts/make-fixtures.sh`
3. Run: `swift run -c release pladder-cli bench bench/fixtures`. It takes
   about seven minutes; leave the machine alone while it runs.
4. Runs never overlap, and every run is preceded by ten seconds of idle so
   it starts from the same state a real dictation does, rather than with
   warm clocks and residual heat from the previous run. `--pause` changes
   the idle time; `--pause 0` gives back-to-back runs, which are faster but
   flatter the numbers.
5. Six runs per fixture. The first, which pays CoreML's first-call warm-up,
   is discarded and the median of the remaining five is reported, with the
   spread of those five (largest minus smallest, relative to the median) as
   the noise floor for that fixture. Fixtures run shortest to longest. When
   a result lands near the noise line and you need to know, `--runs 11`
   keeps ten and takes about twelve minutes.
6. The tool prints the one-minute load average at start and end and tags
   any run during which the chip left its normal thermal state. A run with
   a thermal tag or a load average well above one is not comparable.
7. A difference under roughly ten percent is noise. If a change lands near
   that line, run again.

Baselines from other machines are not comparable to the one below. Add a
separate table with chip, macOS version and model version.

### The paced bench, for engines that transcribe while speaking

`--engine streaming` and `--engine incremental` replace the whole-buffer call
with the live one: each fixture is pushed in one-second chunks paced at real
time, as the coordinator's feed task delivers them, and only `endUtterance`
is timed. That is the part left on the release-to-paste path.

```sh
swift run -c release pladder-cli bench bench/fixtures --engine incremental --runs 2 --pause 2
```

Pacing takes as long as the audio, so fixtures under 13 s are skipped — below
one encoder window both paths make the same single padded pass anyway. `--all`
keeps them. Every fixture also goes through the batch engine once, whole, and
the two raw engine texts are compared before any processor runs; the line
reads `identical: yes`, or `identical: no` with the first differing word and
its index. For the incremental engine that line is a gate, not a metric: it
runs the batch engine's own windows, so anything but `yes` is a bug.

## Baseline

Reference machine: Apple M1, 16 GB, macOS 26.6.2 (25G83), FluidAudio 0.15.6,
model `parakeet-tdt-0.6b-v3` (CoreML). Recorded 2026-09-11 with `--runs 11`,
ten kept runs per fixture. The M1 is the least powerful chip Pladder
supports: if it is fast enough here, it is fast enough everywhere.

| Measurement | Value |
|---|---:|
| Model load, fresh process | 0.26 s (0.18 to 0.32 s across five runs) |
| Physical footprint after load | 98 MB |

The load time is with CoreML's compiled-model cache warm. The very first load
after the download, or after a macOS update invalidates the cache, compiles
the models and takes far longer; that is a one-time cost and not what this
number tracks. The weights run on the Neural Engine and are held outside the
process, so the footprint understates total memory use.

| Fixture | Audio | Engine (median) | Spread | Realtime | WER |
|---|---:|---:|---:|---:|---:|
| 10s | 9.7 s | 0.237 s | 20 % | 41x | 0.0 % |
| 30s | 31.8 s | 0.399 s | 11 % | 80x | 0.0 % |
| 60s | 60.8 s | 0.563 s | 29 % | 108x | 1.4 % |
| 2m | 125.1 s | 0.908 s | 11 % | 138x | 0.9 % |
| 5m | 315.6 s | 1.976 s | 6 % | 160x | 0.6 % |
| 10m | 631.4 s | 3.704 s | 3 % | 170x | 0.6 % |

Ten seconds of idle before every run; load average 1.6 at the start and 3.3
at the end from other processes on the machine; no thermal tags.

How to read the spread: it is the full range of the kept runs, so it grows
with the run count and is set by the outliers. Eight of the ten 60 s runs
sit between 0.547 and 0.573 s; the other two, at 0.645 and 0.712 s, landed
while the load average was climbing. The medians are the stable part. A
six-run pass under the same procedure gave 0.252, 0.398, 0.558, 0.915,
1.963 and 3.698 s: within six percent of this table on the 10 s fixture and
within one percent everywhere else. Compare medians; use the spread to judge
whether the machine was quiet enough for the comparison to mean anything.

Engine time grows close to linearly with audio length; the realtime factor
rises because the fixed cost per call is amortised and long audio keeps four
workers busy.

Two earlier passes without the idle pause gave 0.150 and 0.152 s for the
10 s fixture, 0.34 to 0.36 s for 30 s and 0.50 s for 60 s, with the long
fixtures unchanged. Back-to-back runs inherit warm clocks from the previous
run, which flatters short audio by about 0.1 s. A dictation never gets that,
so those numbers are not the baseline; the pause exists to keep it that way.

The 60 s fixture's errors are two
mishearings, "flowers" heard as "flours" and "rye loaf" merged into one word.
The sentence with "flowers" is transcribed correctly in the 30 s fixture,
where it does not sit near a window boundary, which is the kind of seam
effect the longer fixtures exist to expose.

## Reading the app's release-to-paste log

Every dictation logs one line with the total release-to-paste time, its
per-stage breakdown and the audio length:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```

The line looks like:

```
release-to-paste 0.312 s: stop 0.012, engine 0.250, process 0.003, paste 0.014; audio 4.2 s
```

What each stage contains:

- `stop` is `AudioCapture.stop()`: removing the tap and collecting the
  captured samples.
- `engine` is `TranscriptionEngine.transcribe`.
- `process` is the processor pipeline run.
- `paste` is `TextOutput.insert`.

The remainder of the total after these four stages is actor scheduling: the
coordinator resumes on the main actor between stages. If the remainder grows,
something new is contending with the main actor.

The engine's own `processingTime` is logged beside the stages as
`engine-time`; a large gap between `engine` and `engine-time` means the engine
actor was busy with something else.
