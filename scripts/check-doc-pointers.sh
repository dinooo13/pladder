#!/bin/bash
# Fails when a Swift comment points at a docs/*.md heading that does not exist.
# A pointer is `docs/X.md, "Section"` or `"Section" in docs/X.md`; a comment
# split over several `//` lines is read as one. Headings are levels 1 to 3,
# outside code fences, with backticks removed. A bare `docs/X.md` is fine as
# long as the file exists.
#
# Plain bash 3.2 and POSIX awk, so it runs the same on macOS and ubuntu.

set -eo pipefail
cd "$(dirname "$0")/.."

headings=$(mktemp)
trap 'rm -f "$headings"' EXIT

for doc in docs/*.md; do
    awk -v doc="$doc" '
        { sub(/\r$/, "") }
        /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
        fenced { next }
        match($0, /^#+ /) && RLENGTH <= 4 {
            text = substr($0, RLENGTH + 1)
            gsub(/`/, "", text)
            sub(/[ \t#]+$/, "", text)
            print doc "\t" text
        }
        END { print doc "\t" }
    ' "$doc" >> "$headings"
done

files=()
while IFS= read -r file; do files+=("$file"); done < <(find Sources Tests -name '*.swift' 2>/dev/null | LC_ALL=C sort)
if [ ${#files[@]} -eq 0 ]; then
    echo "no Swift files under Sources or Tests" >&2
    exit 1
fi

awk -v headings="$headings" '
    BEGIN {
        while ((getline line < headings) > 0) {
            tab = index(line, "\t")
            doc = substr(line, 1, tab - 1)
            exists[doc] = 1
            section = substr(line, tab + 1)
            if (section != "") known[doc SUBSEP section] = 1
        }
        close(headings)
    }

    function report(offset, message,    i) {
        for (i = runLines; i > 1 && starts[i] > offset; i--) {}
        printf "%s:%d: %s\n", runFile, runFirst + i - 1, message
        failures++
    }

    # A missing file is reported once, by the bare-name pass.
    function check(doc, section, offset) {
        pointers++
        if ((doc in exists) && !((doc SUBSEP section) in known))
            report(offset, "no heading \"" section "\" in " doc)
    }

    # Every pointer in the joined comment run, in both orders, then every bare file name.
    function scan(    rest, base, hit, doc, section, q) {
        rest = run; base = 0
        while (match(rest, /docs\/[A-Z]+\.md, "[^"]+"/)) {
            hit = substr(rest, RSTART, RLENGTH)
            doc = substr(hit, 1, index(hit, ",") - 1)
            q = index(hit, "\"")
            section = substr(hit, q + 1, length(hit) - q - 1)
            check(doc, section, base + RSTART)
            base += RSTART + RLENGTH - 1
            rest = substr(rest, RSTART + RLENGTH)
        }
        rest = run; base = 0
        while (match(rest, /"[^"]+" in docs\/[A-Z]+\.md/)) {
            hit = substr(rest, RSTART, RLENGTH)
            q = index(substr(hit, 2), "\"") + 1
            section = substr(hit, 2, q - 2)
            doc = substr(hit, q + 5)
            check(doc, section, base + RSTART)
            base += RSTART + RLENGTH - 1
            rest = substr(rest, RSTART + RLENGTH)
        }
        rest = run; base = 0
        while (match(rest, /docs\/[A-Z]+\.md/)) {
            doc = substr(rest, RSTART, RLENGTH)
            if (!(doc in exists)) report(base + RSTART, "no file " doc)
            base += RSTART + RLENGTH - 1
            rest = substr(rest, RSTART + RLENGTH)
        }
    }

    function flush() {
        if (runLines > 0) scan()
        run = ""; runLines = 0
    }

    FNR == 1 { flush(); files++ }

    {
        line = $0
        sub(/\r$/, "", line)
        if (match(line, /^[ \t]*\/\/+[ \t]?/)) {
            text = substr(line, RLENGTH + 1)
            if (runLines == 0) { runFile = FILENAME; runFirst = FNR }
            else run = run " "
            starts[++runLines] = length(run) + 1
            run = run text
        } else {
            flush()
        }
    }

    END {
        flush()
        if (failures > 0) exit 1
        printf "%d pointers to docs/ headings checked in %d Swift files.\n", pointers, files
    }
' "${files[@]}"
