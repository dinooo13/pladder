#!/usr/bin/env bash
# Plays one dictation per overlay path (plain, late and slow transcription,
# clipboard hint, polish, polish on a transcript too short to polish) through
# the real coordinator and pill, records the screen, and cuts a contact sheet
# per path from the release to the end of the fly-out, each frame labelled
# with its time and the coordinator's state. Read the sheets to see what an
# overlay change does without dictating. Needs Screen Recording for the
# terminal that runs it; keep the pointer on the main display, where the pill
# shows and screencapture records.
#
# The demo never starts the hotkey, the microphone, the engine or the paste,
# so it is safe to run while another Pladder is in use. It records under
# scripts/lock.sh's screen lock, so a second demo waits for the first.
#
# Usage: scripts/overlay-demo.sh [dir] [--style compact|minimal|liveTranscript]
#                                      [--reduce-motion]
#        (default dir: /tmp/pladder-overlay-demo)
set -euo pipefail
for arg in "$@"; do
	case "$arg" in -h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="/tmp/pladder-overlay-demo"
if [[ $# -gt 0 && "$1" != --* ]]; then OUT="$1"; shift; fi
swift build --product Pladder -Xswiftc -DPLADDER_DEV_MODES --scratch-path .build/dev-modes
# Again under the screen lock, so the build stays outside it: the second pass
# finds it done.
[[ -n "${PLADDER_LOCK_SCREEN:-}" ]] || exec "$ROOT/scripts/lock.sh" screen -- "$ROOT/scripts/overlay-demo.sh" "$OUT" "$@"
mkdir -p "$OUT"
rm -f "$OUT"/demo.mov "$OUT"/sheet-*.png
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

screencapture -x -v "$OUT/demo.mov" &
RECORDER=$!
# A demo that fails would otherwise leave screencapture recording in the
# background, since `set -e` ends the script before the stop below.
trap 'kill -INT "$RECORDER" 2>/dev/null || true' EXIT
.build/dev-modes/debug/Pladder --overlay-demo "$@" > "$OUT/demo.log"
# Stopped by hand rather than with -V: the stop time less the movie's length
# is when the first frame was taken, which lines the frames up with the log.
STOPPED=$(now)
kill -INT "$RECORDER"
wait "$RECORDER"
trap - EXIT

swift "$ROOT/scripts/overlay-sheets.swift" "$OUT" "$STOPPED"
