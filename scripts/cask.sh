#!/bin/bash
# Prints Casks/pladder.rb for the dinooo13/homebrew-tap repository: the
# template scripts/pladder.rb with a release's version and the SHA-256 of its
# Pladder.dmg. Without a SHA-256 it reads the release's Pladder.dmg.sha256.
# See INSTALL.md, "Homebrew".
#
#   ./scripts/cask.sh 0.1.2 > ../homebrew-tap/Casks/pladder.rb

set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: cask.sh <version> [<sha256>]}
sha=${2:-}

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "cask.sh: version \"$version\" is not major.minor.patch" >&2
    exit 1
fi
if [[ -z "$sha" ]]; then
    sha=$(curl -fsSL "https://github.com/dinooo13/pladder/releases/download/v$version/Pladder.dmg.sha256" | cut -d ' ' -f 1)
fi
if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "cask.sh: \"$sha\" is not a SHA-256" >&2
    exit 1
fi

sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" scripts/pladder.rb
