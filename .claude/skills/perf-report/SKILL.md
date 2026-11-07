---
name: perf-report
description: Weekly performance report for Pladder from the dictation logs of the copy in use on this Mac. Median, p90, p99 and max release-to-paste by recording length and polish, slow releases, compared with the previous report and the baseline in docs/BENCHMARKS.md, and a GitHub issue only for a real regression. Use for the weekly performance report, when asked "how is Pladder performing", or to look at the dictation logs.
---

# Pladder performance report

Turns the `release-to-paste` line that `/Applications/Pladder.app` logs for every real dictation
(`AppModel.handle(.inserted)`, built by `TimingLine.swift`, subsystem `de.dinooo13.pladder`, category
`timing`) into a report for the period since the last one. Read only: it reads the unified log, the
installed app's `Info.plist`, `settings.json` and git, and writes only to its own folder (below).

## Rules

- Run on the MacBook Air (`hostname` is `MacBookAir.fritz.box`). The log is on the Mac; on the code-box,
  say so and stop.
- Never run a benchmark, and never launch, quit or kill any copy of Pladder: the developer dictates with it
  (CLAUDE.md, "Working on this Mac while Pladder is in use"). Never edit `settings.json`.
- The only thing this skill may change outside its folder is one GitHub issue, under the rules in step 4.

## Where the numbers live

`~/Library/Application Support/Pladder/perf-report/`, beside the app's settings, never in the repo:

- `dictations.jsonl`: one line per dictation, numbers only (the log line carries no transcript), copied
  from the log. The unified log keeps these lines for only about a day on this Mac (on 2026-11-07 the
  oldest was 18 hours old), so the ledger is what makes a week possible.
- `builds.json`: the installed binary's UUID with its version, build number and install time, recorded
  whenever a run finds a binary it has not seen. A dictation names the binary that logged it.
- `reports.json`: every saved report's period and per-group numbers. The last entry is the "previous
  report".

`perf_report.py collect` only copies new log lines into the ledger. Any run of it, at any time, keeps
lines that a weekly report would otherwise never see.

## Steps

1. From the repo root, run the report:

   ```sh
   /usr/bin/python3 .claude/skills/perf-report/perf_report.py report
   ```

   This copies new log lines first, then reports the period since the previous report's end (the last
   7 days if there is none) and saves it as the next previous report. For a question in between ("how is
   it doing?"), run `report --days 7 --no-save`, so the weekly period is not cut short.
   Exit status 3 means too few dictations: say how many there were and that 30 are needed, then stop.
   Nothing is saved in that case, so the next report covers this period too.

2. Read the output. The script prints Markdown:
   - **Group table**: plain dictations (polish off) overall, by engine when more than one was in
     settings, by recording length (the baseline's buckets plus "60 s and over"), and polished dictations
     by model. `Waited ≥20 ms` counts releases where `feed + engine − engine-time` was 20 ms or more: a
     release that waited for a window pass the feed loop had in flight (docs/BENCHMARKS.md, "The release
     wait"). `Median remainder` is the total minus the logged stages, the time between stages on the
     main actor; if it grows, something new is contending with the main actor.
   - **Comparison table**: each group's median against the previous report and against the baseline
     table in docs/BENCHMARKS.md ("What a dictation waits for"). `noise` means within 10 %; `too few`
     means either side has fewer than 10 dictations (30 for the whole period).
   - **Builds**: which binaries served the period. Build N maps to main's Nth commit when the app was
     built from main (`bundle.sh` sets CFBundleVersion to the commit count). Local builds replaced
     before any run saw them installed are listed together.
   - **Commits**: those on the release-to-paste path (`Sources/PladderCore`, `Engines`, `Audio`,
     `System`, `Refine`, `Package.*`) between the previous report's build, or the commit that wrote the
     baseline table, and the newest build in the period, with their PR numbers; commits that touched
     only the app target are listed by hash.
   - **Verdict**: `better`, `same` or `worse`, and whether a regression is issue-worthy.

3. Check the verdict before acting on it. A `worse` group means its median rose more than 10 %. Look at
   which stage grew: median `engine`, `Waited` and `Median remainder` against the previous report.
   p90, p99 and max are shown but never decide anything below 30 dictations in a group.

4. Only when the script says `Issue-worthy regression: yes` (a worse group with at least 20 dictations
   in the period, or the whole period with 30): first look for an open one,

   ```sh
   gh issue list --repo dinooo13/pladder --state open --search "release-to-paste in:title"
   ```

   If one is open, comment on it with this period's tables and the new commits. Otherwise open one in
   the shape of recent issues (#84 is the model): a title that says what happens, such as
   "Release-to-paste for 10–20 s recordings is 18 % slower since build 331"; sections `## What happens`,
   `## How often and how much` (the group and comparison tables), `## Suspected commits` (the release-path
   commits with PR links, the most likely first, and why), `## What is not yet clear`, and `## Done when`
   with checkboxes (the cause is named; the group's median is back within 10 % of the baseline over at
   least 20 dictations; any fix has a before-and-after benchmark per docs/BENCHMARKS.md). Label it `bug`.
   Never put a transcript or anything from the clipboard in it; the numbers are all there is. With no
   issue-worthy regression, open and comment on nothing.

5. End with a short report: the group table, the comparison rows that are not `too few`, the verdict in
   one line (better, same or worse, and against what), the build and commit range, the coverage line if
   the script printed one, and the issue link if one was opened or commented on.
