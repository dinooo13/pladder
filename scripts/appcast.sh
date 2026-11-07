#!/usr/bin/env bash
# Signs a release's DMG with the Sparkle EdDSA key and prints its appcast.xml:
# the one feed item the app's SUFeedURL, releases/latest/download/appcast.xml,
# serves until the next release. release.yml publishes it beside the DMG.
#
# Usage: scripts/appcast.sh <Pladder.app> <Pladder.dmg> <notes.md> > appcast.xml
#   <Pladder.app>      the bundle inside the DMG, for its version, build and
#                      minimum system version
#   <notes.md>         scripts/changelog.sh's output; from "## Changes" on, it
#                      becomes the release notes Sparkle's window shows
#   SPARKLE_ED_KEY     the private key, as generate_keys -x writes it; without
#                      it, sign_update takes the key from the login keychain,
#                      account "pladder" (INSTALL.md, "Update signing key")
#   SIGN_UPDATE        default: the one SwiftPM fetched with Sparkle
#   DMG_URL            default: the DMG of the tag v<version>; a local test
#                      feed points it elsewhere
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 3 ]]; then
	echo "usage: scripts/appcast.sh <Pladder.app> <Pladder.dmg> <notes.md>" >&2
	exit 2
fi
APP="$1"
DMG="$2"
NOTES="$3"
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
if [[ ! -x "$SIGN_UPDATE" ]]; then
	echo "no sign_update at $SIGN_UPDATE; run swift package resolve first" >&2
	exit 1
fi

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
PUBLIC_KEY="$(plist SUPublicEDKey)"

sign() {
	if [[ -n "${SPARKLE_ED_KEY:-}" ]]; then
		printf '%s' "$SPARKLE_ED_KEY" | "$SIGN_UPDATE" --ed-key-file - "$@"
	else
		"$SIGN_UPDATE" --account pladder "$@"
	fi
}
DMG_URL="${DMG_URL:-https://github.com/dinooo13/pladder/releases/download/v$VERSION/Pladder.dmg}"
SIGNATURE="$(sign -p "$DMG")"
LENGTH="$(stat -f %z "$DMG")"
# Against the app's own public key, not the private key's: a key that is not the
# app's would publish an update that no copy accepts.
if ! xcrun swift - "$PUBLIC_KEY" "$SIGNATURE" "$DMG" <<'SWIFT'
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard let key = Data(base64Encoded: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let data = FileManager.default.contents(atPath: arguments[3]),
      publicKey.isValidSignature(signature, for: data) else { exit(1) }
SWIFT
then
	echo "the signature of $DMG does not verify against the SUPublicEDKey of $APP" >&2
	exit 1
fi

# The notes are scripts/changelog.sh's few shapes: headings, bullets, paragraphs
# and `code`. Sparkle's window renders HTML; its Markdown is inline only.
NOTES_HTML="$(sed -n '/^## Changes/,$p' "$NOTES" | LC_ALL=C awk '
	function inline(s) {
		gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
		while (match(s, /`[^`]+`/)) {
			s = substr(s, 1, RSTART - 1) "<code>" substr(s, RSTART + 1, RLENGTH - 2) "</code>" substr(s, RSTART + RLENGTH)
		}
		return s
	}
	function close_list() { if (inlist) { print "</ul>"; inlist = 0 } }
	/^### / { close_list(); print "<h3>" inline(substr($0, 5)) "</h3>"; next }
	/^## / { close_list(); print "<h2>" inline(substr($0, 4)) "</h2>"; next }
	/^- / { if (!inlist) { print "<ul>"; inlist = 1 } print "<li>" inline(substr($0, 3)) "</li>"; next }
	/^$/ { close_list(); next }
	{ close_list(); print "<p>" inline($0) "</p>" }
	END { close_list() }
')"
# Inside CDATA only "]]>" needs care.
NOTES_HTML="${NOTES_HTML//]]>/]]]]><![CDATA[>}"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pladder</title>
    <link>https://github.com/dinooo13/pladder/releases</link>
    <language>en</language>
    <item>
      <title>Pladder $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/dinooo13/pladder/releases</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$NOTES_HTML
]]></description>
      <enclosure url="$DMG_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
