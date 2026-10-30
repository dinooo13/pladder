#!/usr/bin/env bash
# Speaks every sentence of the number-word set with two voices per language, as
# 16 kHz mono Float32 WAV, for `pladder-cli numbers`. Nothing here is committed.
#
# Usage: scripts/make-number-fixtures.sh [set.json] [dir]
#   defaults: docs/number-set.json, bench/numbers
#
# Layout: <dir>/<lang>-<voice>/<id>.wav; the CLI picks a case's voices by the
# language prefix. Existing files are kept, so a rerun only adds new cases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="${1:-$ROOT/docs/number-set.json}"
OUT="${2:-$ROOT/bench/numbers}"
RATE="${RATE:-175}"

# Two voices each, so one voice's reading of a number does not decide a kind.
# German has one natural voice installed by default; Eddy is a formant voice.
VOICES=(
	"en:Samantha"
	"en:Daniel"
	"de:Anna"
	"de:Eddy (German (Germany))"
	"es:Mónica"
	"es:Paulina"
)

for entry in "${VOICES[@]}"; do
	voice=${entry#*:}
	if ! say -v '?' | grep -q "^$voice "; then
		echo "voice '$voice' is not installed; add it in System Settings > Accessibility > Spoken Content" >&2
		exit 1
	fi
done

field() { plutil -extract "$1.$2" raw -o - "$SET"; }

made=0
i=0
while id=$(field "$i" id 2>/dev/null); do
	lang=$(field "$i" lang)
	spoken=$(field "$i" spoken)
	for entry in "${VOICES[@]}"; do
		[ "${entry%%:*}" = "$lang" ] || continue
		voice=${entry#*:}
		dir="$OUT/$lang-${voice%% *}"
		wav="$dir/$id.wav"
		[ -f "$wav" ] && continue
		mkdir -p "$dir"
		say -v "$voice" -r "$RATE" -o "$wav" --file-format=WAVE --data-format=LEF32@16000 "$spoken"
		made=$((made + 1))
	done
	i=$((i + 1))
done
echo "$i cases, $made new files in $OUT"
