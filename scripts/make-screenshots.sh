#!/usr/bin/env bash
# Renders the pictures the README shows into docs/images with the app's own
# views: the real overlay pill on a stand-in desktop, light and dark. The
# social preview is drawn by scripts/make-icon.swift. Needs Screen Recording for the terminal that runs it.
# The app it launches never starts the hotkey, the microphone or the engine,
# so it is safe to run while another Pladder is in use; it shows a few
# windows for a second or two.
#
# Usage: scripts/make-screenshots.sh [dir] [--hero | --settings | --settings-scene | --hero-frames]   (default: docs/images)
#   --hero      the site's hero picture, hero-light.png and hero-dark.png, which
#               site/media/hero-* are encoded from
#   --settings  each Settings tab, light and dark, for reviewing the window
#   --settings-scene  the real Settings window, toolbar and key window included
#   --hero-frames     the keyframes scripts/make-hero-loop.sh turns into the site's loop
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/docs/images"
if [[ $# -gt 0 && "$1" != --* ]]; then OUT="$1"; shift; fi

"$ROOT/scripts/bundle.sh"
# The binary directly, not `open`: screencapture then runs with this
# terminal's Screen Recording grant.
"$ROOT/dist/Pladder.app/Contents/MacOS/Pladder" --screenshots "$OUT" "$@"
