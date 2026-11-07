#!/usr/bin/env python3
# The perf-report skill's data step; .claude/skills/perf-report/SKILL.md says how it is used.
# Reads the unified log, the installed app's Info.plist, settings.json and git. Writes only
# under --state-dir.

import argparse
import datetime as dt
import json
import os
import plistlib
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
APP = "/Applications/Pladder.app"
APP_BINARY = APP + "/Contents/MacOS/Pladder"
SETTINGS = HOME + "/Library/Application Support/Pladder/settings.json"
MANAGED_POLICY = "/Library/Managed Preferences/de.dinooo13.pladder.plist"
DEFAULT_STATE_DIR = HOME + "/Library/Application Support/Pladder/perf-report"
REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=os.path.dirname(os.path.abspath(__file__)),
                      capture_output=True, text=True).stdout.strip()

MIN_PERIOD = 30
MIN_BUCKET = 10
MIN_ISSUE_BUCKET = 20
NOISE = 0.10
# bench-release counts a release as having waited at 20 ms or more (docs/BENCHMARKS.md, "The release wait").
WAIT_THRESHOLD = 0.020
FIRST_HARVEST_DAYS = 8

BUCKETS = [(0, 10, "under 10 s"), (10, 20, "10–20 s"), (20, 40, "20–40 s"), (40, 60, "40–60 s"),
           (60, float("inf"), "60 s and over")]
RELEASE_PATH = ["Sources/PladderCore", "Sources/PladderEngines", "Sources/PladderAudio", "Sources/PladderSystem",
                "Sources/PladderRefine", "Package.swift", "Package.resolved"]
APP_TARGET = "Sources/Pladder"

LINE = re.compile(
    r"^(?P<polished>polished )?release-to-paste (?P<total>[\d.]+) s: "
    r"(?:feed (?P<feed>[\d.]+), )?stop (?P<stop>[\d.]+), engine (?P<engine>[\d.]+), "
    r"process (?P<process>[\d.]+), (?:polish (?P<polish>[\d.]+) \((?P<model>[^)]*)\), )?"
    r"paste (?P<paste>[\d.]+); audio (?P<audio>[\d.]+) s, engine-time (?P<engine_time>[\d.]+) s$")


# MARK: State

def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def read_ledger(state_dir):
    path = os.path.join(state_dir, "dictations.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def parse_time(stamp):
    return dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z")


# MARK: Collect

def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def installed_build():
    try:
        with open(APP + "/Contents/Info.plist", "rb") as f:
            info = plistlib.load(f)
    except FileNotFoundError:
        return None
    uuid = re.search(r"UUID: ([0-9A-F-]{36}) \(arm64\)", run(["dwarfdump", "--uuid", APP_BINARY]).stdout)
    if not uuid:
        return None
    installed = dt.datetime.fromtimestamp(os.path.getmtime(APP_BINARY)).astimezone()
    return uuid.group(1), {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                           "installed": installed.isoformat(timespec="seconds")}


def current_engine():
    return read_json(SETTINGS, {}).get("engineID", "default")


def collect(state_dir):
    os.makedirs(state_dir, exist_ok=True)
    ledger = read_ledger(state_dir)
    seen = {(d["ts"], d["pid"]) for d in ledger}
    if ledger:
        # A minute of overlap: log show's --start has one-second resolution; the seen set drops repeats.
        start = max(parse_time(d["ts"]) for d in ledger) - dt.timedelta(minutes=1)
        window = ["--start", start.astimezone().strftime("%Y-%m-%d %H:%M:%S")]
    else:
        window = ["--last", "%dd" % FIRST_HARVEST_DAYS]
    out = run(["/usr/bin/log", "show", "--style", "ndjson", *window, "--predicate",
               'subsystem == "de.dinooo13.pladder" AND category == "timing"'])
    if out.returncode != 0:
        sys.exit("log show failed: " + out.stderr.strip())

    engine = current_engine()
    added, other_copies, unparsed = [], 0, 0
    for raw in out.stdout.splitlines():
        try:
            event = json.loads(raw)
        except ValueError:
            continue
        if event.get("eventType") != "logEvent":
            continue
        if event.get("processImagePath") != APP_BINARY:
            other_copies += 1
            continue
        match = LINE.match(event.get("eventMessage", ""))
        if not match:
            unparsed += 1
            continue
        key = (event["timestamp"], event["processID"])
        if key in seen:
            continue
        seen.add(key)
        fields = match.groupdict()
        entry = {"ts": event["timestamp"], "pid": event["processID"], "binary": event.get("processImageUUID"),
                 "engineID": engine, "polished": bool(fields.pop("polished")), "model": fields.pop("model")}
        entry.update({k: float(v) for k, v in fields.items() if v is not None})
        entry.setdefault("feed", 0.0)
        added.append(entry)

    if added:
        with open(os.path.join(state_dir, "dictations.jsonl"), "a") as f:
            for entry in added:
                f.write(json.dumps(entry) + "\n")

    builds_path = os.path.join(state_dir, "builds.json")
    builds = read_json(builds_path, {})
    current = installed_build()
    if current and current[0] not in builds:
        builds[current[0]] = dict(current[1], firstSeen=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
        write_json(builds_path, builds)
    return {"added": len(added), "otherCopies": other_copies, "unparsed": unparsed}


# MARK: Statistics

def quantile(sorted_values, q):
    if not sorted_values:
        return None
    position = (len(sorted_values) - 1) * q
    low = int(position)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def waited(d):
    return d["feed"] + d["engine"] - d["engine_time"]


def remainder(d):
    return d["total"] - sum(d.get(k, 0.0) for k in ("feed", "stop", "engine", "process", "polish", "paste"))


def summarise(group):
    totals = sorted(d["total"] for d in group)
    waits = sorted(waited(d) for d in group if waited(d) >= WAIT_THRESHOLD)
    return {
        "n": len(group),
        "audio": quantile(sorted(d["audio"] for d in group), 0.5),
        "median": quantile(totals, 0.5), "p90": quantile(totals, 0.9), "p99": quantile(totals, 0.99),
        "max": totals[-1] if totals else None,
        "waited": len(waits), "waitMedian": quantile(waits, 0.5),
        "engine": quantile(sorted(d["engine"] for d in group), 0.5),
        "remainder": quantile(sorted(remainder(d) for d in group), 0.5),
    }


def bucket_of(d):
    return next(label for low, high, label in BUCKETS if low <= d["audio"] < high)


# MARK: Baseline and git

def baseline():
    path = os.path.join(REPO, "docs/BENCHMARKS.md")
    with open(path) as f:
        lines = f.read().splitlines()
    header = next((i for i, l in enumerate(lines) if l.startswith("| Recording | Dictations | Median length |")), None)
    if header is None:
        return {}, None
    rows = {}
    for number, line in enumerate(lines[header + 2:], start=header + 3):
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 4:
            break
        rows[cells[0]] = {"n": int(cells[1]), "median": float(cells[3].rstrip(" s")), "line": number}
    if not rows:
        return {}, None
    first = min(r["line"] for r in rows.values())
    blame = run(["git", "blame", "--porcelain", "-L", "%d,%d" % (first, first), "docs/BENCHMARKS.md"], cwd=REPO)
    anchor = blame.stdout.split(" ", 1)[0] if blame.returncode == 0 and blame.stdout else None
    return rows, anchor


def main_ref():
    run(["git", "fetch", "--quiet", "origin", "main"], cwd=REPO, timeout=30)
    for ref in ("origin/main", "main"):
        if run(["git", "rev-parse", "--verify", "--quiet", ref], cwd=REPO).returncode == 0:
            return ref
    return "HEAD"


# bundle.sh and release.sh set CFBundleVersion to `git rev-list --count HEAD`; main is linear,
# so build N is main's Nth commit when the app was built from main.
def commit_for_build(build, ref):
    try:
        number = int(build)
    except (TypeError, ValueError):
        return None
    commits = run(["git", "rev-list", "--reverse", "--first-parent", ref], cwd=REPO).stdout.split()
    return commits[number - 1] if 0 < number <= len(commits) else None


def commits_between(old, new, paths, look_up_pr):
    out = run(["git", "log", "--format=%H %s", "%s..%s" % (old, new), "--", *paths], cwd=REPO).stdout
    commits = []
    for line in out.splitlines():
        sha, subject = line.split(" ", 1)
        pr = ""
        if look_up_pr:
            pr = run(["gh", "pr", "list", "--repo", "dinooo13/pladder", "--state", "merged", "--search", sha,
                      "--json", "number", "--jq", ".[0].number"], cwd=REPO, timeout=30).stdout.strip()
        commits.append({"sha": sha[:7], "subject": subject, "pr": int(pr) if pr.isdigit() else None})
    return commits


# MARK: Report

def ms(seconds):
    return "–" if seconds is None else "%.0f ms" % (seconds * 1000)


def change(new, old):
    if new is None or old is None or old == 0:
        return None
    return (new - old) / old


def pct(value):
    return "–" if value is None else "%+.0f %%" % (value * 100)


def compare(label, current, other, minimum, source):
    if not other:
        return None
    delta = change(current["median"], other["median"])
    eligible = current["n"] >= minimum and other["n"] >= minimum and delta is not None
    verdict = "noise"
    if eligible and delta > NOISE:
        verdict = "worse"
    elif eligible and delta < -NOISE:
        verdict = "better"
    elif not eligible:
        verdict = "too few"
    issue = verdict == "worse" and current["n"] >= (MIN_PERIOD if label == "all" else MIN_ISSUE_BUCKET)
    return {"group": label, "against": source, "n": current["n"], "otherN": other["n"], "median": current["median"],
            "otherMedian": other["median"], "change": delta, "verdict": verdict, "issue": issue}


def report(args):
    state_dir = args.state_dir
    harvest = collect(state_dir)
    ledger = read_ledger(state_dir)
    builds = read_json(os.path.join(state_dir, "builds.json"), {})
    reports_path = os.path.join(state_dir, "reports.json")
    reports = read_json(reports_path, [])
    previous = reports[-1] if reports else None

    end = dt.datetime.now().astimezone()
    if args.days is None and previous:
        start = dt.datetime.fromisoformat(previous["end"])
    else:
        start = end - dt.timedelta(days=args.days or 7)
    period = [d for d in ledger if start <= parse_time(d["ts"]) < end]
    plain = [d for d in period if not d["polished"]]
    polished = [d for d in period if d["polished"]]
    first_recorded = min((parse_time(d["ts"]) for d in ledger), default=None)

    p = print
    p("# Pladder release-to-paste, %s to %s" % (start.strftime("%Y-%m-%d %H:%M"), end.strftime("%Y-%m-%d %H:%M")))
    p()
    p("Dictations in the period: %d (%d plain, %d polished). New log lines copied to the ledger: %d."
      % (len(period), len(plain), len(polished), harvest["added"]))
    if first_recorded and first_recorded > start:
        p("Coverage: the ledger starts %s; the unified log keeps these lines for about a day, "
          "so the period before that is missing." % first_recorded.strftime("%Y-%m-%d %H:%M"))
    if harvest["otherCopies"]:
        p("Timing lines left out, from copies other than %s (worktree and test builds): %d."
          % (APP, harvest["otherCopies"]))
    if harvest["unparsed"]:
        p("Unparsed: %d timing lines did not match the expected format; check TimingLine.swift." % harvest["unparsed"])
    policy = read_json_plist(MANAGED_POLICY)
    if policy.get("AllowedEngines"):
        p("Note: a managed policy allows only %s; a build that reads it may run that engine instead of the "
          "engine in settings.json." % ", ".join(policy["AllowedEngines"]))
    p()

    if len(plain) < MIN_PERIOD:
        p("**Too few dictations**: %d plain dictations, %d needed for a verdict. Nothing saved, so the next "
          "report covers this period too." % (len(plain), MIN_PERIOD))
        return 3

    rows = [("all", summarise(plain))]
    engines = sorted({d["engineID"] for d in plain})
    if len(engines) > 1:
        rows += [("engine " + e, summarise([d for d in plain if d["engineID"] == e])) for e in engines]
    for _, _, label in BUCKETS:
        group = [d for d in plain if bucket_of(d) == label]
        if group:
            rows.append((label, summarise(group)))
    for model in sorted({d["model"] for d in polished}):
        rows.append(("polished, " + model, summarise([d for d in polished if d["model"] == model])))

    p("Engine (settings.json when the lines were copied): %s." % ", ".join(engines))
    p()
    p("| Group | Dictations | Median audio | Median | p90 | p99 | Max | Waited ≥20 ms | Median wait | Median remainder |")
    p("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for label, s in rows:
        p("| %s | %d | %.1f s | %s | %s | %s | %s | %d | %s | %.1f ms |" % (
            label, s["n"], s["audio"], ms(s["median"]), ms(s["p90"]), ms(s["p99"]), ms(s["max"]),
            s["waited"], ms(s["waitMedian"]), s["remainder"] * 1000))
    p()

    base, anchor = baseline()
    if not base:
        p("Baseline: the release-to-paste table was not found in docs/BENCHMARKS.md; compared with the previous "
          "report only.")
        p()
    comparisons = []
    summaries = dict(rows)
    for label, s in rows:
        if previous and label in previous["groups"]:
            comparisons.append(compare(label, s, previous["groups"][label],
                                       MIN_PERIOD if label == "all" else MIN_BUCKET, "previous report"))
        if label in base:
            comparisons.append(compare(label, s, base[label], MIN_BUCKET, "baseline"))
    comparisons = [c for c in comparisons if c]

    p("| Group | Against | Dictations (now / then) | Median now | Median then | Change | Verdict |")
    p("|---|---|---:|---:|---:|---:|---|")
    for c in comparisons:
        p("| %s | %s | %d / %d | %s | %s | %s | %s |" % (c["group"], c["against"], c["n"], c["otherN"],
                                                       ms(c["median"]), ms(c["otherMedian"]), pct(c["change"]),
                                                       c["verdict"]))
    if not previous:
        p()
        p("No previous report: this is the first, compared with the baseline only.")
    p()

    by_binary = {}
    for d in period:
        by_binary.setdefault(d["binary"], []).append(d)
    ref = main_ref()
    p("Builds that served the period:")
    p()
    newest_commit = None
    unknown = []
    for binary, group in sorted(by_binary.items(), key=lambda item: min(d["ts"] for d in item[1])):
        info = builds.get(binary)
        if not info:
            unknown.append(group)
            continue
        commit = commit_for_build(info["build"], ref)
        newest_commit = commit or newest_commit
        s = summarise([d for d in group if not d["polished"]] or group)
        p("- %s (%s), binary %s, installed %s: %d dictations, median %s, remainder %.1f ms; build %s is %s on "
          "main if it was built from main" % (info["version"], info["build"], binary[:8], info["installed"],
                                              len(group), ms(s["median"]), s["remainder"] * 1000, info["build"],
                                              commit[:7] if commit else "no commit"))
    if unknown:
        flat = sorted((d for group in unknown for d in group), key=lambda d: d["ts"])
        s = summarise([d for d in flat if not d["polished"]] or flat)
        p("- %d binaries replaced before a collect saw them installed (local builds), %s to %s: %d dictations, "
          "median %s, remainder %.1f ms" % (len(unknown), flat[0]["ts"][:16], flat[-1]["ts"][:16], len(flat),
                                            ms(s["median"]), s["remainder"] * 1000))
    p()

    since = (previous.get("commit") if previous else None) or anchor
    if since and newest_commit and since != newest_commit:
        suspects = commits_between(since, newest_commit, RELEASE_PATH, look_up_pr=True)
        app_only = [c for c in commits_between(since, newest_commit, [APP_TARGET], look_up_pr=False)
                    if c["sha"] not in {s["sha"] for s in suspects}]
        p("Commits on the release-to-paste path (%s) from %s (%s) to %s:"
          % (", ".join(RELEASE_PATH), since[:7], "previous report" if since != anchor else "the baseline table",
             newest_commit[:7]))
        p()
        for c in suspects:
            p("- %s %s%s" % (c["sha"], c["subject"], " (#%d)" % c["pr"] if c["pr"] else ""))
        if not suspects:
            p("- none")
        if app_only:
            p()
            p("%d more touched only the app target (%s), which shares the main actor: %s"
              % (len(app_only), APP_TARGET, ", ".join(c["sha"] for c in app_only)))
        p()

    verdicts = {c["verdict"] for c in comparisons}
    verdict = "worse" if "worse" in verdicts else "better" if "better" in verdicts else "same"
    regression = [c for c in comparisons if c["issue"]]
    p("**Verdict: %s.**" % verdict)
    p("Issue-worthy regression: %s." % ("yes, " + "; ".join(
        "%s against the %s %s" % (c["group"], c["against"], pct(c["change"])) for c in regression)
        if regression else "no"))
    p("Rules: a verdict needs %d plain dictations in the period; a group is compared when both sides have %d "
      "(the whole period %d); a change under %d %% is noise; an issue needs a worse group with at least %d "
      "dictations in the period, or the whole period." % (MIN_PERIOD, MIN_BUCKET, MIN_PERIOD, NOISE * 100,
                                                          MIN_ISSUE_BUCKET))

    if not args.no_save:
        reports.append({"generated": end.isoformat(timespec="seconds"), "start": start.isoformat(timespec="seconds"),
                        "end": end.isoformat(timespec="seconds"), "commit": newest_commit, "verdict": verdict,
                        "groups": summaries})
        write_json(reports_path, reports)
    return 0


def read_json_plist(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except (FileNotFoundError, PermissionError, plistlib.InvalidFileException):
        return {}


def main():
    parser = argparse.ArgumentParser(description="Pladder's release-to-paste report from the app's own log.")
    parser.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("collect", help="copy new timing lines into the ledger and print what was copied")
    rep = sub.add_parser("report", help="collect, then report the period since the last saved report")
    rep.add_argument("--days", type=int, help="report the last N days instead of since the last report")
    rep.add_argument("--no-save", action="store_true", help="do not record this report as the previous one")
    args = parser.parse_args()
    if args.command == "collect":
        print(json.dumps(collect(args.state_dir)))
        return 0
    return report(args)


if __name__ == "__main__":
    sys.exit(main())
