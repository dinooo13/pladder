#!/bin/bash
# Fails when the site states a measurement that docs/BENCHMARKS.md does not.
# A measurement is a number with a unit (ms, s, %, x, MB, GB). On the site
# each one is the text of a link to a BENCHMARKS.md heading, `<a href=".../
# docs/BENCHMARKS.md#section">0.195 s</a>` or the Markdown form in llms.txt,
# and that exact text must appear under that heading. A measurement anywhere
# else in a page, its meta tags and JSON-LD included, fails. One link per
# line, as the pages are written.
#
# It also checks that every page names the same release, and with --release
# that it is the latest one on GitHub and its DMG's SHA-256 (needs `gh`).
#
# Plain bash 3.2 and POSIX awk, so it runs the same on macOS and ubuntu.

set -eo pipefail
cd "$(dirname "$0")/.."

sections=$(mktemp)
trap 'rm -f "$sections"' EXIT

# Each line of BENCHMARKS.md with the slug GitHub gives its heading.
awk '
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fenced = !fenced }
    !fenced && match($0, /^#+ /) && RLENGTH <= 4 {
        slug = tolower(substr($0, RLENGTH + 1))
        gsub(/[^a-z0-9 _-]/, "", slug)
        gsub(/ /, "-", slug)
        print slug "\t"
    }
    { print slug "\t" $0 }
' docs/BENCHMARKS.md > "$sections"

files=()
while IFS= read -r file; do files+=("$file"); done < <(find site -name '*.html' -o -name '*.txt' | LC_ALL=C sort)

awk -v sections="$sections" '
    BEGIN {
        while ((getline line < sections) > 0) {
            tab = index(line, "\t")
            slug = substr(line, 1, tab - 1)
            known[slug] = 1
            text[slug] = text[slug] "\n" substr(line, tab + 1)
        }
        close(sections)
        doc = "https://github\\.com/dinooo13/pladder/blob/main/docs/BENCHMARKS\\.md#"
        html = "<a href=\"" doc "[a-z0-9_-]+\"[^>]*>[^<]*</a>"
        markdown = "\\[[^]]*\\]\\(" doc "[a-z0-9_-]+\\)"
        figure = "[0-9]+(\\.[0-9]+)? ?(ms|s|%|x|MB|GB)([^A-Za-z0-9]|$)"
    }

    function check(slug, shown) {
        figures++
        if (!(slug in known)) {
            printf "%s:%d: no heading #%s in docs/BENCHMARKS.md\n", FILENAME, FNR, slug
            failures++
        } else if (index(text[slug], shown) == 0) {
            printf "%s:%d: \"%s\" is not under #%s in docs/BENCHMARKS.md\n", FILENAME, FNR, shown, slug
            failures++
        }
    }

    {
        line = $0
        # Pixel densities, file names and drawing, such as "2x", "@2x.jpg" or a
        # the width of a bar in a style, are not measurements.
        gsub(/(srcset|style)="[^"]*"/, "", line)
        while (match(line, html)) {
            start = RSTART; span = RLENGTH
            hit = substr(line, start, span)
            slug = hit; sub(/^[^#]*#/, "", slug); sub(/".*$/, "", slug)
            shown = hit; sub(/^<a [^>]*>/, "", shown); sub(/<\/a>$/, "", shown)
            if (match(shown, figure)) check(slug, shown)
            line = substr(line, 1, start - 1) " " substr(line, start + span)
        }
        while (match(line, markdown)) {
            start = RSTART; span = RLENGTH
            hit = substr(line, start, span)
            shown = substr(hit, 2, index(hit, "](") - 2)
            slug = hit; sub(/^[^#]*#/, "", slug); sub(/\)$/, "", slug)
            if (match(shown, figure)) check(slug, shown)
            line = substr(line, 1, start - 1) " " substr(line, start + span)
        }
        gsub(/(src|href)="[^"]*"/, "", line)
        gsub(/https?:\/\/[^ "<>)]*/, "", line)
        if (match(line, figure)) {
            printf "%s:%d: \"%s\" is not a link to docs/BENCHMARKS.md\n", FILENAME, FNR, substr(line, RSTART, RLENGTH)
            failures++
        }
    }

    END {
        if (failures > 0) exit 1
        printf "%d figures on the site match docs/BENCHMARKS.md.\n", figures
    }
' "${files[@]}"

# The release the pages name: the visible version, the checksum, the JSON-LD
# and every "for version" line must agree.
version=$(sed -n 's/.*<span id="version">\([^<]*\)<.*/\1/p' site/index.html)
sha=$(sed -n 's/.*<code id="sha256">\([0-9a-f]*\)<.*/\1/p' site/index.html)
if [ -z "$version" ] || [ ${#sha} -ne 64 ]; then
    echo "site/index.html: no version or SHA-256 beside the download button" >&2
    exit 1
fi
stale=$(grep -rhoE '"softwareVersion": "[^"]*"|for version [0-9][0-9.]*[0-9]' site \
    | grep -vF "\"softwareVersion\": \"$version\"" | grep -vF "for version $version" || true)
if [ -n "$stale" ]; then
    echo "the site names version $version beside the button, but also: $stale" >&2
    exit 1
fi

if [ "$1" = "--release" ]; then
    latest=$(gh api repos/dinooo13/pladder/releases/latest --jq '.tag_name | ltrimstr("v")')
    if [ "$latest" != "$version" ]; then
        echo "the site names version $version, the latest release is $latest" >&2
        exit 1
    fi
    # The fixed-name asset the button downloads, or the versioned one with the same bytes.
    digest=$(gh api repos/dinooo13/pladder/releases/latest --jq \
        "[.assets[] | select(.name == \"Pladder.dmg\" or .name == \"Pladder-$version.dmg\")][0].digest")
    if [ "$digest" != "sha256:$sha" ]; then
        echo "the site gives SHA-256 $sha, the latest release's DMG has ${digest:-none}" >&2
        exit 1
    fi
    echo "Version $version and its SHA-256 match the latest release."
else
    echo "Every page names version $version."
fi
