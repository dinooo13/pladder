#!/usr/bin/env bash
# Generates the benchmark fixtures: synthetic speech from a fixed script at six
# lengths, as 16 kHz mono Float32 WAV (the format the engine takes), with the
# spoken text beside each file so the benchmark can compute word error rate.
#
# Nothing here is committed. There is no personal audio in the repo and anyone
# can regenerate the same fixtures on any Mac with the same voice.
#
# Usage: scripts/make-fixtures.sh [dir]     default: bench/fixtures
#   VOICE=<name>   say voice, default Samantha (en_US, ships with macOS)
#   RATE=<wpm>     speaking rate, default 175
#
# Lengths: 10 s (one encoder window), 30 s, 60 s, 2 min (the app's recording
# cap), 5 min and 10 min (beyond the cap, CLI only). The script is read in
# sentence order, wrapping around for the long fixtures, until the estimated
# duration reaches the target, so each file is a whole number of sentences.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/bench/fixtures}"
VOICE="${VOICE:-Samantha}"
RATE="${RATE:-175}"

NAMES=(10s 30s 60s 2m 5m 10m)
TARGETS=(10 30 60 120 300 600)

# Plain prose, one sentence per line. No digits, abbreviations, contractions
# or words with regional spellings, so the reference and the transcript can
# only differ where the engine actually misheard.
SENTENCES=(
	"The morning train left the station a few minutes after seven."
	"A thin fog still covered the fields on both sides of the track."
	"Most of the passengers were reading or looking out of the window."
	"The conductor walked slowly through the carriage and checked every ticket."
	"By the time we reached the river the sun had burned the fog away."
	"The old bridge has been closed to cars for almost a decade."
	"People still cross it on foot to reach the market on the far bank."
	"On Saturdays the square fills with stalls selling bread, cheese and flowers."
	"My grandmother used to buy her apples from the same family every week."
	"She said the trick was to press the skin gently near the stem."
	"If it gives a little, the fruit is ripe and will taste sweet."
	"The bakery on the corner opens before dawn and closes at noon."
	"Their rye loaf is dense and dark and keeps well for several days."
	"Behind the church there is a small park with a pond and two benches."
	"In summer the ducks nest in the reeds and the children feed them crumbs."
	"The library moved into the former post office building last spring."
	"It has tall windows, a reading room, and a quiet corner for students."
	"A librarian told me that the local history shelf is the most popular."
	"Many visitors want to find the house where their grandparents lived."
	"The town hall clock strikes every hour, but it runs a few minutes slow."
	"Nobody seems to mind, and some people say it gives them extra time."
	"In the evening the coffee shops put their chairs out on the pavement."
	"The waiters know most customers by name and bring their usual order."
	"A cup of coffee costs a little more here than in the city."
	"But the view of the water makes the price feel fair."
	"Fishing boats return at dusk and unload their catch at the pier."
	"Gulls follow them in from the sea, hoping for something to fall."
	"The lighthouse was automated years ago, yet a keeper still lives there."
	"He gives tours on Sunday afternoons and tells stories about storms."
	"One winter the waves reached the second floor and broke the glass."
	"The lamp kept turning all night and every ship came home safely."
	"Walking back along the beach you can collect smooth green stones."
	"Local people call them sea glass and use them to decorate window sills."
	"The path climbs steeply past the ruins of a stone mill."
	"From the top you can see three villages and the hills beyond."
	"On clear days the mountains on the horizon look close enough to touch."
	"A bus runs back to the station every half hour until late."
	"The last one is usually full of tired hikers and sleeping dogs."
	"When the doors close the driver turns down the radio and pulls away."
	"The lights of the town shrink behind us as the road curves inland."
	"It is a short journey, but it always feels like coming home."
	"Tomorrow the same train will leave again just after seven."
	"Perhaps the fog will be there, and perhaps the bridge will be busy."
	"Either way the bread will be fresh and the coffee will be hot."
	"That is more than enough reason to make the trip again."
)

if ! say -v '?' | grep -q "^$VOICE "; then
	echo "voice '$VOICE' is not installed; pick one from: say -v '?'" >&2
	exit 1
fi

mkdir -p "$OUT"

# say renders straight to 16 kHz mono Float32 WAV; no separate resample step.
synth() { # text file, output wav
	say -v "$VOICE" -r "$RATE" -f "$1" -o "$2" --file-format=WAVE --data-format=LEF32@16000
}
duration() { afinfo "$1" | awk '/estimated duration/ {print $3}'; }
words() { wc -w <"$1" | tr -d ' '; }

# Calibrate words per second for this voice and rate on the first sentences,
# then size each fixture by word count. Speech synthesis is not exactly
# linear in words, so the actual durations are printed and the benchmark
# reports them; they land within a few percent of the targets.
CAL="$OUT/.calibrate"
printf '%s\n' "${SENTENCES[@]:0:6}" >"$CAL.txt"
synth "$CAL.txt" "$CAL.wav"
WPS=$(awk -v w="$(words "$CAL.txt")" -v d="$(duration "$CAL.wav")" 'BEGIN { printf "%.4f", w / d }')
rm -f "$CAL.txt" "$CAL.wav"
echo "voice $VOICE at $RATE wpm speaks $WPS words per second"

COUNT=${#SENTENCES[@]}
for i in "${!NAMES[@]}"; do
	name=${NAMES[$i]}
	target=${TARGETS[$i]}
	needed=$(awk -v s="$target" -v r="$WPS" 'BEGIN { printf "%d", s * r + 0.999 }')
	txt="$OUT/$name.txt"
	wav="$OUT/$name.wav"
	: >"$txt"
	have=0
	idx=0
	while [ "$have" -lt "$needed" ]; do
		line=${SENTENCES[$((idx % COUNT))]}
		count=$(echo "$line" | wc -w)
		# Stop short if the last sentence would overshoot by more than it helps.
		if [ "$have" -gt 0 ] && [ $((have + count - needed)) -gt $((needed - have)) ]; then
			break
		fi
		printf '%s\n' "$line" >>"$txt"
		have=$((have + count))
		idx=$((idx + 1))
	done
	synth "$txt" "$wav"
	printf '%-4s %6.1f s  %4d words  %s\n' "$name" "$(duration "$wav")" "$have" "$wav"
done
