#!/usr/bin/env bash
# Builds a signed, notarised and stapled dist/release/Pladder-<version>.dmg.
# Run by hand on the Mac; it publishes nothing. Tagging and `gh release
# create` stay manual, as INSTALL.md, "Releasing", describes.
#
# Usage: scripts/release.sh <version>       e.g. scripts/release.sh 0.1.0
#   NOTARY_PROFILE     notarytool keychain profile, default pladder-notary
#   CODESIGN_IDENTITY  default: the first Developer ID Application identity
#
# Needs, once: a Developer ID Application certificate in the login keychain
# and `xcrun notarytool store-credentials pladder-notary`. Both stay in the
# keychain; nothing secret is read from the repo or the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: scripts/release.sh <major.minor.patch>" >&2
	exit 2
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-pladder-notary}"

# A release is built from a commit, so the tag names exactly what is in it.
if [[ -n "$(git status --porcelain)" ]]; then
	echo "the working tree has uncommitted changes; commit or set them aside first" >&2
	exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"
BUILD="$(git rev-list --count HEAD)"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
	CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
		| grep -E '"Developer ID Application' \
		| head -1 | sed -E 's/^[^"]*"([^"]+)".*$/\1/' || true)
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
	echo "no Developer ID Application identity in the keychain" >&2
	exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	echo "no usable notarytool profile \"$NOTARY_PROFILE\"; run xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
	exit 1
fi

APP="$ROOT/dist/Pladder.app"
OUT="$ROOT/dist/release"
DMG="$OUT/Pladder-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

# Waits for the verdict and fails on anything but Accepted, printing Apple's
# log, which names the offending file.
notarise() {
	local file="$1" result id status
	echo "Notarising $(basename "$file")…"
	result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
		--wait --output-format json)
	id=$(plutil -extract id raw -o - - <<<"$result")
	status=$(plutil -extract status raw -o - - <<<"$result")
	echo "  $id: $status"
	if [[ "$status" != "Accepted" ]]; then
		xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
		exit 1
	fi
}

MARKETING_VERSION="$VERSION" BUILD_NUMBER="$BUILD" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
	"$ROOT/scripts/bundle.sh" --release
codesign --verify --deep --strict --verbose=2 "$APP"

# The app is notarised and stapled on its own as well as inside the DMG, so
# the copy dragged to /Applications carries its ticket and opens offline.
ditto -c -k --keepParent "$APP" "$OUT/Pladder.zip"
notarise "$OUT/Pladder.zip"
rm "$OUT/Pladder.zip"
xcrun stapler staple "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Pladder.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pladder" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
notarise "$DMG"
xcrun stapler staple "$DMG"

spctl -a -vvv -t exec "$APP"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo
echo "Pladder $VERSION (build $BUILD, $COMMIT)"
cat "$OUT/$(basename "$DMG").sha256"
