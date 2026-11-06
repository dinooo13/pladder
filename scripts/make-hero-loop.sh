#!/usr/bin/env bash
# Renders the site's hero loop: a dictation from press to paste, every frame the
# app's own window and pill in one state (`Pladder --screenshots --hero-frames`),
# crossfaded by ffmpeg into site/media/hero-loop-{light,dark}.{mp4,webm}. The site
# shows the still hero picture instead under Reduce Motion and on phones.
#
# Never starts the hotkey, the microphone or the engine, so it is safe beside a copy
# in use; it shows a few windows for a few seconds. Needs Screen Recording for the
# terminal and ffmpeg with libx264 and libvpx.
#
# Usage: scripts/make-hero-loop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT

swift build --product Pladder
.build/debug/Pladder --screenshots "$FRAMES" --hero-frames > /dev/null

FADE=0.12
add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a + b }'; }
for scheme in light dark; do
  inputs=()
  filter=""
  offset=0
  index=0
  last="0:v"
  # The first frame again at the end, so the loop closes on what it opens with.
  while read -r name seconds; do
    inputs+=(-loop 1 -t "$(add "$seconds" "$FADE")" -i "$FRAMES/$name-$scheme.png")
    if (( index > 0 )); then
      filter+="[${last}][${index}:v]xfade=transition=fade:duration=${FADE}:offset=${offset}[v${index}];"
      last="v$index"
    fi
    offset=$(add "$offset" "$seconds")
    index=$((index + 1))
  done < <(cat "$FRAMES/durations.txt"; echo; head -n 1 "$FRAMES/durations.txt")
  filter="${filter%;}"
  # Up to the end of the fade back into the first frame, which the loop then starts on.
  total=$(add "$(add "$offset" "-$(head -n 1 "$FRAMES/durations.txt" | cut -d ' ' -f 2)")" "$FADE")
  out="site/media/hero-loop-$scheme"
  ffmpeg -y -loglevel error "${inputs[@]}" -filter_complex "$filter" -map "[$last]" -t "$total" -r 30 \
    -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -movflags +faststart -an "$out.mp4"
  ffmpeg -y -loglevel error -i "$out.mp4" -c:v libvpx-vp9 -pix_fmt yuv420p -crf 32 -b:v 0 -an "$out.webm"
  echo "wrote $out.mp4 and $out.webm"
done
