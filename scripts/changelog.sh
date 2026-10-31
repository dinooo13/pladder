#!/usr/bin/env bash
# Prints the release notes for the commits between two refs as Markdown:
# the sections every release carries, then one line per commit subject,
# grouped by the area before its colon. release.yml publishes exactly this,
# so running it by hand previews a release's notes.
#
# Usage: scripts/changelog.sh <from-tag> [<to-ref>]
#   scripts/changelog.sh v0.1.0 HEAD     preview the next release
#   scripts/changelog.sh v0.1.0 v0.1.1   the notes of 0.1.1
#   scripts/changelog.sh "" HEAD         the whole history
#
# Plain bash 3.2 and POSIX awk, so it runs the same on macOS and ubuntu.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: scripts/changelog.sh <from-tag> [<to-ref>]" >&2
	exit 2
fi
FROM="$1"
TO="${2:-HEAD}"
for ref in "$FROM" "$TO"; do
	if [[ -n "$ref" ]] && ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
		echo "no such ref: $ref" >&2
		exit 1
	fi
done
RANGE="$TO"
SINCE=""
if [[ -n "$FROM" ]]; then
	RANGE="$FROM..$TO"
	SINCE=" since $FROM"
fi

cat <<EOF
Requires macOS 26 or later on an Apple Silicon Mac (M1 or newer). Open \`Pladder.dmg\` and drag Pladder to Applications.

The DMG's SHA-256 is in \`Pladder.dmg.sha256\`; with both files in one folder, \`shasum -a 256 -c Pladder.dmg.sha256\` checks it.

- Pladder does not check for updates, since that would be a network call. Watch the releases instead.
- The speech model, about 600 MB, downloads from Hugging Face once, at first launch.
- A move from a copy built yourself with an Apple Development certificate makes macOS ask for Microphone and Accessibility once more.

## Changes$SINCE

EOF

# One record per commit, oldest first: subject, then body. Merges are left out
# here, fixups in awk.
git log --no-merges --reverse --format='%s%x1f%b%x1e' "$RANGE" | LC_ALL=C awk '
	BEGIN {
		RS = "\036"; FS = "\037"
		# Close spellings of one area, keyed in lower case.
		split("hotkey=Hotkeys hotkeys=Hotkeys engine=Engines engines=Engines " \
			"localization=Localisation localisation=Localisation setting=Settings " \
			"docs=Docs readme=README benchmark=Benchmarks benchmarks=Benchmarks " \
			"test=Tests tests=Tests", pairs, " ")
		for (i in pairs) { split(pairs[i], kv, "="); spelling[kv[1]] = kv[2] }
		# Areas folded into a larger one, after the spelling map.
		folds ="S1-mini=Polish|Refine=Polish|Mute=Output|Paste=Output|Pasteboard=Output|" \
			"Clipboard keeper=Output|Live card=Overlay|Live transcript=Overlay|" \
			"Fillers=Processors|Custom words=Processors|Spoken punctuation=Processors|" \
			"Text processors=Processors|Menu bar=App|Quit=App|Capture=App|Recording cap=App|" \
			"Permission monitor=App|Push to talk=Hotkeys|Carbon=Hotkeys|Dictionary tab=Settings|" \
			"Model download=Engines|One engine=Engines|Overlay demo=Internals"
		n = split(folds, pairs, "|")
		for (i = 1; i <= n; i++) { split(pairs[i], kv, "="); fold[kv[1]] = kv[2] }
		# The user-visible areas, in the order the notes list them. A subject
		# whose area starts with one of these words joins it ("Polish model"),
		# unless it is a test ("Coordinator tests").
		n = split("Core Coordinator Engines Hotkeys Overlay Output Polish Learning " \
			"Processors Settings Localisation App CLI", order, " ")
		for (i = 1; i <= n; i++) known[order[i]] = 1
		split("Tests CI Bench Benchmarks Docs README INSTALL CLAUDE.md Scripts Comments Log", list, " ")
		for (i in list) internal[list[i]] = 1
	}
	function canonical(word,   l) {
		l = tolower(word)
		return (l in spelling) ? spelling[l] : word
	}
	function areaof(area,   first, rest) {
		area = canonical(area)
		if (area in fold) return fold[area]
		if (area in internal || area ~ / tests$/) return "Internals"
		first = area; sub(/[ ,].*/, "", first); first = canonical(first)
		if (first in fold) return fold[first]
		if (first in internal) return "Internals"
		if (first in known) return first
		return area
	}
	# Issue references in the body: "Closes #61.", "Refs #84, #88", "fixes #9".
	function refs(body,   s, m, verb, nums, out, key, seen, closes, others) {
		s = tolower(body)
		closes = ""; others = ""
		while (match(s, /(^|[^a-z])(close[sd]?|fix|fixe[sd]|resolve[sd]?|refs?)[: ]+#[0-9]+([ ]*,[ ]*#[0-9]+)*/)) {
			m = substr(s, RSTART, RLENGTH)
			s = substr(s, RSTART + RLENGTH)
			verb = (m ~ /ref/) ? "refs" : "closes"
			while (match(m, /#[0-9]+/)) {
				key = substr(m, RSTART, RLENGTH)
				m = substr(m, RSTART + RLENGTH)
				if (verb == "closes" && !(key in seen)) { closes = closes ", " key; seen[key] = "closes" }
				else if (verb == "refs" && !(key in seen)) { others = others ", " key; seen[key] = "refs" }
			}
		}
		out = ""
		if (closes != "") out = "closes " substr(closes, 3)
		if (others != "") out = out (out == "" ? "" : "; ") "refs " substr(others, 3)
		return out
	}
	{
		subject = $1; body = $2
		sub(/^\n+/, "", subject)
		if (subject == "" || subject ~ /^(fixup|squash|amend)! /) next
		area = ""; text = subject
		# An area is a short label: "Part A of the plan: ..." is a sentence.
		if (match(subject, /^[^:]+: /) && split(substr(subject, 1, RLENGTH - 2), words, " ") <= 4) {
			area = canonical(substr(subject, 1, RLENGTH - 2))
			text = substr(subject, RLENGTH + 1)
		}
		group = (area == "") ? "Other" : areaof(area)
		line = (area == "" || area == group) ? text : area ": " text
		pr = ""
		if (match(line, / \(#[0-9]+\)$/)) {
			pr = substr(line, RSTART + 2, RLENGTH - 3)
			line = substr(line, 1, RSTART - 1)
		}
		r = refs(body)
		links = pr
		if (r != "") links = links (links == "" ? "" : "; ") r
		if (links != "") line = line " (" links ")"
		if (!(group in lines)) groups[++ngroups] = group
		lines[group] = lines[group] "- " line "\n"
	}
	END {
		if (ngroups == 0) { print "No changes."; exit }
		for (i = 1; i <= n; i++) if (order[i] in lines) emit(order[i])
		# The rest alphabetically, then the subjects without an area, then Internals.
		m = 0
		for (i = 1; i <= ngroups; i++) {
			g = groups[i]
			if (!(g in known) && g != "Other" && g != "Internals") rest[++m] = g
		}
		for (i = 2; i <= m; i++) {
			g = rest[i]
			for (j = i - 1; j >= 1 && rest[j] > g; j--) rest[j + 1] = rest[j]
			rest[j + 1] = g
		}
		for (i = 1; i <= m; i++) emit(rest[i])
		if ("Other" in lines) emit("Other")
		if ("Internals" in lines) emit("Internals")
	}
	function emit(g) {
		if (emitted++) printf "\n"
		printf "### %s\n\n%s", g, lines[g]
	}
'
