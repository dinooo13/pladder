#!/usr/bin/env bash
# Renders the pictures the README shows into docs/images with the app's own
# views: the real overlay pill on a stand-in desktop, light and dark, and the
# social preview card. Needs Screen Recording for the terminal that runs it.
# The app it launches never starts the hotkey, the microphone or the engine,
# so it is safe to run while another Pladder is in use; it shows a few
# windows for a second or two.
#
# Usage: scripts/make-screenshots.sh [dir]   (default: docs/images)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${1:-$ROOT/docs/images}"

"$ROOT/scripts/bundle.sh"
# The binary directly, not `open`: screencapture then runs with this
# terminal's Screen Recording grant.
"$ROOT/dist/Pladder.app/Contents/MacOS/Pladder" --screenshots "$OUT"

# GitHub caps the social preview upload at 1 MB; 1280×640 is its native size.
sips -z 640 1280 "$OUT/social-preview.png" >/dev/null
