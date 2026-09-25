#!/usr/bin/env bash
# Plays one dictation per overlay path (plain, slow transcription, clipboard
# hint, polish, polish on a transcript too short to polish) through the real
# coordinator and pill, records the screen, and cuts a contact sheet per path
# from the release to the end of the fly-out, each frame labelled with its
# time and the coordinator's state. Read the sheets to see what an overlay
# change does without dictating. Needs Screen Recording for the terminal
# that runs it; keep the pointer on the main display, where the pill shows
# and screencapture records.
#
# The demo never starts the hotkey, the microphone, the engine or the paste,
# so it is safe to run while another Pladder is in use.
#
# Usage: scripts/overlay-demo.sh [dir] [--style compact|minimal|liveTranscript]
#                                      [--speed instant|quick|expressive]
#        (default dir: /tmp/pladder-overlay-demo)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="/tmp/pladder-overlay-demo"
if [[ $# -gt 0 && "$1" != --* ]]; then OUT="$1"; shift; fi
mkdir -p "$OUT"
rm -f "$OUT"/demo.mov "$OUT"/sheet-*.png

swift build --product Pladder
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

screencapture -x -v "$OUT/demo.mov" &
RECORDER=$!
.build/debug/Pladder --overlay-demo "$@" > "$OUT/demo.log"
# Stopped by hand rather than with -V: the stop time less the movie's length
# is when the first frame was taken, which lines the frames up with the log.
STOPPED=$(now)
kill -INT "$RECORDER"
wait "$RECORDER"

swift "$ROOT/scripts/overlay-sheets.swift" "$OUT" "$STOPPED"
