#!/usr/bin/env bash
# Builds a signed, notarised and stapled dist/release/Pladder.dmg.
# Run by release.yml or by hand on the Mac; it publishes nothing. The
# workflow tags and publishes; by hand, INSTALL.md, "Releasing", says how.
#
# Usage: scripts/release.sh <version>       e.g. scripts/release.sh 0.1.0
#   NOTARY_PROFILE     notarytool keychain profile, default pladder-notary
#   NOTARY_KEY         path of an App Store Connect API key (.p8); with
#   NOTARY_KEY_ID      its key ID and
#   NOTARY_ISSUER      its issuer ID, notarytool signs in with the key instead
#   CODESIGN_IDENTITY  default: the first Developer ID Application identity
#
# Needs, once: a Developer ID Application certificate in the keychain and
# either `xcrun notarytool store-credentials pladder-notary` or the API key.
# Nothing secret is read from the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: scripts/release.sh <major.minor.patch>" >&2
	exit 2
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-pladder-notary}"
if [[ -n "${NOTARY_KEY:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER:-}" ]]; then
	if [[ -z "${NOTARY_KEY:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER:-}" ]]; then
		echo "NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER go together; set all three or none" >&2
		exit 2
	fi
	NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
	NOTARY_HINT="check the API key file and its key and issuer IDs"
else
	NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
	NOTARY_HINT="run xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

# A release is built from a commit, so the tag names exactly what is in it.
if [[ -n "$(git status --porcelain)" ]]; then
	echo "the working tree has uncommitted changes; commit or set them aside first" >&2
	exit 1
fi
# A shallow clone counts only the commits it fetched.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
	echo "a shallow clone gives the wrong build number; fetch the whole history" >&2
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
if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
	echo "notarytool cannot sign in with ${NOTARY_AUTH[0]}; $NOTARY_HINT" >&2
	exit 1
fi

APP="$ROOT/dist/Pladder.app"
OUT="$ROOT/dist/release"
DMG="$OUT/Pladder.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

# Waits for the verdict and fails on anything but Accepted, printing Apple's
# log, which names the offending file.
notarise() {
	local file="$1" result id status
	echo "Notarising $(basename "$file")…"
	result=$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" \
		--wait --output-format json)
	id=$(plutil -extract id raw -o - - <<<"$result")
	status=$(plutil -extract status raw -o - - <<<"$result")
	echo "  $id: $status"
	if [[ "$status" != "Accepted" ]]; then
		xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
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
