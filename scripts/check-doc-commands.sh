#!/bin/bash
# Fails when a document names a script or a pladder-cli command that does not
# exist. A script is `scripts/<name>.<ext>`, also as `./scripts/…`, or a bare
# `<name>.sh`, anywhere in the text, and must be in scripts/. A command is the
# word after `pladder-cli ` in backticks or a code fence, when it is lowercase
# letters and hyphens (not a path, placeholder or flag), and must be a
# top-level `case "…":` label in Sources/PladderCLI/main.swift. Those labels
# must be the commands the CLI's usage text lists, so neither can change alone.
#
# Usage: scripts/check-doc-commands.sh [file …]    default: CLAUDE.md
#
# Plain bash 3.2 and POSIX awk, so it runs the same on macOS and ubuntu.

set -eo pipefail
for arg in "$@"; do
	case "$arg" in -h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/Sources/PladderCLI/main.swift"
if [[ $# -eq 0 ]]; then cd "$ROOT" && set -- CLAUDE.md; fi

labels=$(awk '/^case "/ {
	line = $0
	while (match(line, /"[^"]*"/)) {
		print substr(line, RSTART + 1, RLENGTH - 2)
		line = substr(line, RSTART + RLENGTH)
	}
}' "$MAIN" | sort -u)
listed=$(awk '!/^[ \t]*\/\// {
	line = $0
	while (match(line, /pladder-cli [a-z][a-z-]*/)) {
		print substr(line, RSTART + 12, RLENGTH - 12)
		line = substr(line, RSTART + RLENGTH)
	}
}' "$MAIN" | sort -u)
if [[ -z "$labels" || "$labels" != "$listed" ]]; then
	echo "$MAIN: the case labels ($(paste -s -d " " - <<<"$labels")) are not the commands the usage text lists ($(paste -s -d " " - <<<"$listed"))" >&2
	exit 1
fi

failed=0
scripts=0
commands=0
for doc in "$@"; do
	found=$(awk '
		function scripts_in(text,    rest, before, name) {
			rest = text
			while (match(rest, /scripts\/[A-Za-z0-9_-]+\.[A-Za-z0-9]+/)) {
				before = substr(rest, 1, RSTART - 1)
				name = substr(rest, RSTART, RLENGTH)
				rest = substr(rest, RSTART + RLENGTH)
				sub(/\.\/$/, "", before)
				if (before !~ /[A-Za-z0-9_.\/-]$/) print NR "\tscript\t" name
			}
			rest = text
			while (match(rest, /[A-Za-z0-9_-]+\.sh/)) {
				before = substr(rest, 1, RSTART - 1)
				name = substr(rest, RSTART, RLENGTH)
				rest = substr(rest, RSTART + RLENGTH)
				if (before !~ /[A-Za-z0-9_.\/-]$/ && rest !~ /^[A-Za-z0-9_]/) print NR "\tscript\tscripts/" name
			}
		}
		function commands_in(code,    rest, word) {
			rest = code
			while (match(rest, /pladder-cli +[^ \t`]+/)) {
				word = substr(rest, RSTART, RLENGTH)
				rest = substr(rest, RSTART + RLENGTH)
				sub(/^pladder-cli +/, "", word)
				if (word ~ /^[a-z][a-z-]*$/) print NR "\tcommand\t" word
			}
		}
		{ sub(/\r$/, "") }
		/^[ \t]*(```|~~~)/ { fenced = !fenced; next }
		{ scripts_in($0) }
		fenced { commands_in($0); next }
		{
			n = split($0, part, "`")
			for (i = 2; i <= n; i += 2) commands_in(part[i])
		}
	' "$doc")
	while IFS="$(printf '\t')" read -r line kind name; do
		[[ -n "$kind" ]] || continue
		if [[ "$kind" == script ]]; then
			scripts=$((scripts + 1))
			if [[ ! -e "$ROOT/$name" ]]; then
				echo "$doc:$line: $name does not exist" >&2
				failed=1
			fi
		else
			commands=$((commands + 1))
			if ! grep -qxF -- "$name" <<<"$labels"; then
				echo "$doc:$line: pladder-cli $name is not a command; there are $(paste -s -d " " - <<<"$labels")" >&2
				failed=1
			fi
		fi
	done <<<"$found"
done

if [[ "$failed" -ne 0 ]]; then exit 1; fi
echo "$scripts script names and $commands pladder-cli commands, all of them there"
