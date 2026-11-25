#!/usr/bin/env bash
# Runs a command while it holds one of the things every worktree on this Mac
# shares, so two runs that need it go one after the other: `screen` for
# anything that records the screen, `ane` for anything that measures (the
# Neural Engine and the GPU: benchmarks and polish timings). The lock is held
# until the command ends, however it ends; one whose holder is gone is taken
# over by the next run. A command run under it sees PLADDER_LOCK_SCREEN or
# PLADDER_LOCK_ANE, and a lock.sh inside it for the same lock just runs.
#
# Usage: scripts/lock.sh [--wait <seconds>] <screen|ane> -- <command> [argument …]
#        scripts/lock.sh --status [screen|ane]
#   --wait <seconds>  how long to wait for the holder; default 3600, 0 fails at once
#   --status          who holds each lock
#   PLADDER_LOCK_DIR  where the locks are kept; default /tmp
# Exits with the command's own status, 75 when the wait ran out, 1 when the
# lock cannot be made, 2 on a usage error. -h and --help count only before --.
set -uo pipefail
for arg in "$@"; do
	case "$arg" in
	--) break ;;
	-h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${PLADDER_LOCK_DIR:-/tmp}"
RESOURCES="screen ane"

usage() {
	echo "lock.sh: $1" >&2
	echo "Usage: scripts/lock.sh [--wait <seconds>] <screen|ane> -- <command> [argument …]" >&2
	echo "       scripts/lock.sh --status [screen|ane]" >&2
	exit 2
}

WAIT=3600
STATUS=0
RESOURCE=""
COMMAND=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--) COMMAND=1; shift; break ;;
	--wait)
		[[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage "--wait takes a number of seconds"
		WAIT=$2
		shift 2
		;;
	--status) STATUS=1; shift ;;
	-*) usage "unknown option: $1" ;;
	*)
		[[ -z "$RESOURCE" ]] || usage "one resource only"
		RESOURCE=$1
		shift
		;;
	esac
done
if [[ -n "$RESOURCE" && " $RESOURCES " != *" $RESOURCE "* ]]; then
	usage "no resource called $RESOURCE; there are $RESOURCES"
fi

field() { # <name> <owner file>
	[[ -f "$2" ]] || return 0
	sed -n "s/^$1=//p" "$2" | head -n 1
}

# lstart in one locale and zone, so the same process always reads the same.
started() {
	LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>&1 | tr -s ' ' | sed 's/^ //;s/ $//'
	return "${PIPESTATUS[0]}"
}

# A process is gone only when ps ran and found nothing under its PID, or found
# another process that took the PID over; a ps that failed to run counts as
# alive, so a lock is never taken from a holder that could not be checked.
alive() { # <pid> <start time>
	local out
	[[ "$1" =~ ^[0-9]+$ ]] || return 0
	if out=$(started "$1"); then
		[[ -z "$2" || "$out" == "$2" ]]
		return
	fi
	[[ -n "$out" ]]
}

# 0: held by a live process, 1: its holder is gone, 2: held by hand or still
# being written, so never taken over.
holder() { # <lock dir>
	local owner="$1/owner" pid
	pid=$(field pid "$owner")
	[[ -n "$pid" ]] || return 2
	alive "$pid" "$(field started "$owner")" && return 0
	pid=$(field command-pid "$owner")
	[[ -n "$pid" ]] && alive "$pid" "$(field command-started "$owner")" && return 0
	return 1
}

describe() { # <resource>
	local lock="$DIR/pladder-$1.lock" owner="$DIR/pladder-$1.lock/owner" state since epoch minutes
	if [[ ! -d "$lock" ]]; then
		echo "$1: free"
		return
	fi
	holder "$lock"
	state=$?
	case "$state" in
	0)
		since=$(field time "$owner")
		epoch=$(field epoch "$owner")
		minutes=$((($(date +%s) - ${epoch:-$(date +%s)}) / 60))
		echo "$1: held by $(field worktree "$owner") ($(field branch "$owner")), pid $(field pid "$owner"), since ${since##* } ($minutes min): $(field command "$owner")"
		;;
	1) echo "$1: left by pid $(field pid "$owner") (gone); the next run takes it over" ;;
	*)
		if [[ -f "$owner" ]]; then
			echo "$1: held by hand: $(paste -s -d ' ' "$owner")"
		else
			echo "$1: held by hand: $lock has no owner file"
		fi
		;;
	esac
}

if [[ "$STATUS" -eq 1 ]]; then
	[[ "$COMMAND" -eq 0 ]] || usage "--status runs no command"
	for resource in ${RESOURCE:-$RESOURCES}; do describe "$resource"; done
	exit 0
fi
[[ -n "$RESOURCE" ]] || usage "name a resource"
[[ "$COMMAND" -eq 1 && $# -gt 0 ]] || usage "give the command after --"

LOCK="$DIR/pladder-$RESOURCE.lock"
OWNER="$LOCK/owner"
case "$RESOURCE" in
screen) NESTED="${PLADDER_LOCK_SCREEN:-}" ;;
ane) NESTED="${PLADDER_LOCK_ANE:-}" ;;
esac
if [[ -n "$NESTED" && "$(field pid "$OWNER")" == "$NESTED" ]]; then
	exec "$@"
fi

# Waits for the holder; removes a lock only when its holder is gone, and only
# under the takeover lock, after reading the owner again, so two runs never
# both remove it and one never removes the lock the other just took.
take_over() {
	# A takeover lasts milliseconds, so one older than a minute was left by a
	# run killed inside it. Two waiters clearing it at once can both get in;
	# that needs a SIGKILL here and two runs within milliseconds, so it stays.
	if [[ -n "$(find "$LOCK.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
		rmdir "$LOCK.takeover" 2>/dev/null
	fi
	mkdir "$LOCK.takeover" 2>/dev/null || return 0
	TAKING=1
	local pid
	pid=$(field pid "$OWNER")
	holder "$LOCK"
	if [[ $? -eq 1 ]]; then
		rm -rf "$LOCK"
		echo "lock.sh: took over $RESOURCE from pid $pid, which is gone" >&2
	fi
	TAKING=0
	rmdir "$LOCK.takeover"
}

TAKEN=0
TAKING=0
# A lock this run made but has not yet written its pid into is still its own.
# shellcheck disable=SC2329
release() {
	if [[ "$TAKING" -eq 1 ]]; then rmdir "$LOCK.takeover" 2>/dev/null; fi
	if [[ "$TAKEN" -eq 1 ]]; then
		local pid
		pid=$(field pid "$OWNER")
		if [[ -z "$pid" || "$pid" == "$$" ]]; then rm -rf "$LOCK"; fi
	fi
}
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

deadline=$((SECONDS + WAIT))
seen=""
until mkdir "$LOCK" 2>/dev/null && TAKEN=1; do
	if [[ ! -d "$LOCK" ]]; then
		# Released between the two looks, or a directory this shell cannot make.
		mkdir "$LOCK" 2>/dev/null && TAKEN=1 && break
		if [[ ! -d "$LOCK" ]]; then
			echo "lock.sh: cannot make $LOCK" >&2
			exit 1
		fi
	fi
	holder "$LOCK"
	if [[ $? -eq 1 ]]; then
		take_over
		[[ -d "$LOCK" ]] || continue
	fi
	now="$(field pid "$OWNER") $(field epoch "$OWNER")"
	if [[ "$now" != "$seen" ]]; then
		echo "lock.sh: waiting for $(describe "$RESOURCE")" >&2
		seen=$now
	fi
	if [[ $SECONDS -ge $deadline ]]; then
		echo "lock.sh: gave up on $RESOURCE after ${WAIT} s; scripts/lock.sh --status $RESOURCE says who has it" >&2
		exit 75
	fi
	sleep 2
done

{
	echo "worktree=$ROOT"
	echo "branch=$(git -C "$ROOT" branch --show-current 2>/dev/null)"
	echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
	echo "epoch=$(date +%s)"
	echo "pid=$$"
	echo "started=$(started $$)"
	line="$*"
	echo "command=${line//$'\n'/ }"
} >"$OWNER"

case "$RESOURCE" in
screen) export PLADDER_LOCK_SCREEN=$$ ;;
ane) export PLADDER_LOCK_ANE=$$ ;;
esac
# The command's own PID and start time go in the owner file before it starts,
# so a lock.sh that is killed outright still leaves the lock held until the
# command it started is done too.
# shellcheck disable=SC2016
sh -c 'owner=$1; shift
	s=$(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ 2>/dev/null | tr -s " " | sed "s/^ //;s/ $//")
	printf "command-pid=%s\ncommand-started=%s\n" "$$" "$s" >>"$owner"
	exec "$@"' lock.sh "$OWNER" "$@"
exit $?
