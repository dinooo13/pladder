#!/usr/bin/env bash
# Launches this worktree's dist/Pladder.app as a test copy beside the copy in
# use, and prints its PID on stdout. The copy gets a settings file of its own,
# /tmp/<branch>/settings.json, written fresh at every launch, and a chord the
# copy in use never reacts to: one whose key none of the live chords uses and
# that holds no live modifier-only chord, chosen from the live settings file,
# which is only read. Builds dist/Pladder.app with scripts/bundle.sh first,
# every time, and stops this worktree's earlier test copy.
#
# Usage: scripts/test-copy.sh [--stop | --dry-run]
#   --stop     stop this worktree's test copy, and no other copy
#   --dry-run  print the chord and the settings file; build, write and launch nothing
#   The copy's output goes to /tmp/<branch>/test-copy.log.
set -euo pipefail
for arg in "$@"; do
	case "$arg" in -h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done

MODE=start
case "${1:-}" in
"") ;;
--stop) MODE=stop ;;
--dry-run) MODE=dry-run ;;
*)
	echo "unknown argument: $1" >&2
	exit 2
	;;
esac
[[ $# -le 1 ]] || { echo "one argument at most" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/dist/Pladder.app/Contents/MacOS/Pladder"
BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
DIR="/tmp/${BRANCH:-$(basename "$ROOT")}"
SETTINGS="$DIR/settings.json"
LIVE="$HOME/Library/Application Support/Pladder/settings.json"

# Matched by the whole command line, not a pattern: `--screenshots` runs of
# the same binary carry arguments, and other worktrees' copies another path.
copies() {
	local pid
	for pid in $(pgrep -x Pladder || true); do
		if [[ "$(ps -ww -o command= -p "$pid" 2>/dev/null)" == "$BIN" ]]; then echo "$pid"; fi
	done
}

others() {
	local pid line
	for pid in $(pgrep -x Pladder || true); do
		line=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
		if [[ "$line" == */dist/Pladder.app/Contents/MacOS/Pladder && "$line" != "$BIN" ]]; then echo "$pid $line"; fi
	done
}

# SIGTERM only: the app gives back the speakers and the clipboard on it, and
# ends itself 5 s later if that hangs.
stop() {
	local pids pid running
	pids=$(copies | paste -s -d ' ' -)
	[[ -n "$pids" ]] || return 0
	# shellcheck disable=SC2086
	kill -TERM $pids 2>/dev/null || true
	for _ in $(seq 30); do
		sleep 0.2
		running=""
		for pid in $pids; do
			if kill -0 "$pid" 2>/dev/null; then running="$running $pid"; fi
		done
		if [[ -z "$running" ]]; then
			echo "stopped test copy $pids" >&2
			return 0
		fi
	done
	echo "test copy$running still running 6 s after SIGTERM; not killing it" >&2
	return 1
}

if [[ "$MODE" == stop ]]; then
	if [[ -z "$(copies)" ]]; then
		echo "no test copy of $ROOT is running" >&2
		exit 0
	fi
	stop
	exit
fi

# MARK: The chord

MODIFIERS=" 54 55 56 58 59 60 61 62 63 "
collapse() { # Right Command, Shift, Option and Control count as the left ones
	case "$1" in 54) echo 55 ;; 60) echo 56 ;; 61) echo 58 ;; 62) echo 59 ;; *) echo "$1" ;; esac
}

command -v jq >/dev/null || { echo "test-copy.sh needs jq" >&2; exit 1; }
# The defaults' keys count whatever the file says: Option+Space and V.
LIVE_CHORDS="hotkey 49 58
submitKey 9"
if [[ -e "$LIVE" ]]; then
	if ! read_chords=$(jq -r '
		if type != "object" then error("not a settings object") else . end
		| ["hotkey", "toggleHotkey", "submitKey"][] as $k
		| select(.[$k] != null)
		| .[$k] as $c
		| if ($c | type) == "object" and ($c.keyCodes | type) == "array" and ($c.keyCodes | all(type == "number"))
		  then "\($k) \($c.keyCodes | map(tostring) | join(" "))"
		  else error("\($k) has no list of key codes") end
	' "$LIVE" 2>&1); then
		echo "cannot read the chords in $LIVE, so no chord is known to be free: $read_chords" >&2
		exit 1
	fi
	LIVE_CHORDS="$LIVE_CHORDS
$read_chords"
fi

USED_KEYS=" "
HELD_MODIFIERS=""
while read -r role codes; do
	[[ -n "$role" ]] || continue
	only=" "
	regular=0
	for code in $codes; do
		if [[ "$MODIFIERS" == *" $code "* ]]; then
			only="$only$(collapse "$code") "
		else
			USED_KEYS="$USED_KEYS$code "
			regular=1
		fi
	done
	if [[ "$role" != submitKey && "$regular" -eq 0 && "$only" != " " ]]; then
		HELD_MODIFIERS="$HELD_MODIFIERS$only
"
	fi
done <<<"$LIVE_CHORDS"

# A modifier-only chord fires on its modifiers alone, so a candidate holding
# all of them would start the copy in use on the way to its own chord.
holds_live_chord() { # <candidate codes>
	local mods=" " code chord
	for code in "$@"; do mods="$mods$(collapse "$code") "; done
	while read -r chord; do
		[[ -n "$chord" ]] || continue
		local inside=1
		for code in $chord; do
			if [[ "$mods" != *" $code "* ]]; then inside=0; fi
		done
		if [[ "$inside" -eq 1 ]]; then return 0; fi
	done <<<"$HELD_MODIFIERS"
	return 1
}

# One regular key and no fn, so Carbon can register it without Accessibility
# and the copy never falls back to Option+Space.
CANDIDATES="⌃⌥⌘ 55 58 59
⌃⌥⇧ 56 58 59
⌃⇧⌘ 55 56 59
⌥⇧⌘ 55 56 58
⌃⇧ 56 59"
CHORD=""
for key in "T 17" "G 5"; do
	read -r letter code <<<"$key"
	[[ "$USED_KEYS" != *" $code "* ]] || continue
	while read -r symbols mods; do
		# shellcheck disable=SC2086
		if ! holds_live_chord $mods; then
			CHORD="$code $mods"
			NAME="$symbols$letter"
			break 2
		fi
	done <<<"$CANDIDATES"
done
if [[ -z "$CHORD" ]]; then
	echo "every candidate chord clashes with one in $LIVE; launching nothing" >&2
	exit 1
fi
# shellcheck disable=SC2086
CODES=$(printf '%s\n' $CHORD | sort -n | paste -s -d , -)
JSON="{\"hotkey\":{\"keyCodes\":[$CODES]},\"toggleHotkey\":{\"keyCodes\":[]}}"

if [[ "$MODE" == dry-run ]]; then
	echo "chord: $NAME"
	echo "settings: $SETTINGS"
	echo "$JSON"
	exit 0
fi

# MARK: Launch

while read -r pid line; do
	[[ -n "$pid" ]] || continue
	echo "warning: another worktree's test copy is running, pid $pid: $line" >&2
done <<<"$(others)"

stop
# Every time: scripts/make-screenshots.sh leaves a developer-modes bundle in
# the same dist.
"$ROOT/scripts/bundle.sh" >&2
mkdir -p "$DIR"
# Without a settings file the app opens Settings, which would take focus and
# the next paste of the copy in use.
echo "$JSON" >"$SETTINGS"
PLADDER_SETTINGS_PATH="$SETTINGS" nohup "$BIN" </dev/null >"$DIR/test-copy.log" 2>&1 &
PID=$!
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
	echo "the test copy exited at once; its log, $DIR/test-copy.log:" >&2
	tail -n 20 "$DIR/test-copy.log" >&2
	exit 1
fi
echo "test copy running: pid $PID, chord $NAME, settings $SETTINGS, log $DIR/test-copy.log; stop it with scripts/test-copy.sh --stop" >&2
echo "$PID"
