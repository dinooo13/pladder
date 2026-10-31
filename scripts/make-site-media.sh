#!/usr/bin/env bash
# Turns a screen recording of a dictation (MOV, MP4 or GIF) into a demo the
# site can play: an MP4 (H.264, every browser), a WebM (VP9, smaller where it
# plays) and a poster frame, which shows before either loads. Needs ffmpeg
# with libx264 and libvpx (`brew install ffmpeg`).
#
# Usage: scripts/make-site-media.sh <recording> [poster second, default 6]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="${1:?usage: scripts/make-site-media.sh <recording> [poster second]}"
POSTER_AT="${2:-6}"
OUT="$ROOT/site/media"
mkdir -p "$OUT"

# At most 1200 px wide, even dimensions and yuv420p: Safari plays no other
# H.264. No audio track, so the video may autoplay.
SCALE="scale='min(1200,iw)':-2,format=yuv420p"
ffmpeg -v error -y -i "$IN" -vf "$SCALE" -r 20 \
	-c:v libx264 -preset veryslow -crf 26 -movflags +faststart -an "$OUT/demo.mp4"
ffmpeg -v error -y -i "$IN" -vf "$SCALE" -r 20 \
	-c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 -an "$OUT/demo.webm"
ffmpeg -v error -y -ss "$POSTER_AT" -i "$IN" -vf "scale='min(1200,iw)':-2" \
	-frames:v 1 -q:v 4 "$OUT/demo-poster.jpg"

# The page's <video> needs these as its width and height.
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT/demo.mp4"
ls -l "$OUT"
