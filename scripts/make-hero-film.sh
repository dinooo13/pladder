#!/usr/bin/env bash
# Records the site's hero film: one dictation, press to paste, played by the app's own
# chat window and Liquid Glass pill (`Pladder --screenshots <dir> --hero-video`) and
# captured with ScreenCaptureKit from that window alone, then encoded as
# site/media/hero-film-{light,dark}.{mp4,webm}. It plays once, under five seconds, and
# ends on the pasted reply; the site shows the still hero under Reduce Motion and on phones.
#
# Never starts the hotkey, the microphone or the engine, so it is safe beside a copy in
# use; it shows a window for a few seconds and records nothing else on the screen. Needs
# Screen Recording for the terminal and ffmpeg with libx264 and libvpx.
#
# Usage: scripts/make-hero-film.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FILMS="$(mktemp -d)"
trap 'rm -rf "$FILMS"' EXIT

swift build --product Pladder
.build/debug/Pladder --screenshots "$FILMS" --hero-video > /dev/null

for scheme in light dark; do
  out="site/media/hero-film-$scheme"
  # The last frame, the pasted reply, held for 0.9 s: the capture ends at the last change.
  # Tagged BT.709, limited range, so browsers decode the page colour where it was.
  ffmpeg -y -loglevel error -i "$FILMS/hero-film-$scheme.mov" -vf "fps=30,tpad=stop_mode=clone:stop_duration=0.9,scale=out_color_matrix=bt709:out_range=tv" \
    -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -movflags +faststart \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -an "$out.mp4"
  ffmpeg -y -loglevel error -i "$out.mp4" -c:v libvpx-vp9 -pix_fmt yuv420p -crf 32 -b:v 0 \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -an "$out.webm"
  # Shown behind the film until it paints, so it does not pop in.
  ffmpeg -y -loglevel error -i "$out.mp4" -frames:v 1 -q:v 3 "site/media/hero-film-first-$scheme.jpg"
  echo "wrote $out.mp4 and $out.webm"
done
