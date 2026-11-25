#!/usr/bin/env bash
# Checks that a release went out: the GitHub release, its three files, the
# appcast's version, build and EdDSA signature, the DMG's notarisation and the
# app inside it, the Homebrew cask, and the releases/latest/download links.
# Read only: it reads GitHub and downloads the files into a temporary
# directory, and mounts the DMG read-only and hidden to read the app. It
# never reads local git state, so it runs from any checkout.
#
# Usage: scripts/check-release.sh <version>
#   scripts/check-release.sh 0.2.1
#
# One line per check, PASS, FAIL or SKIP, then a summary. A draft skips what
# only a published release has (latest, cask, latest-download); Linux skips
# what needs macOS (gatekeeper, staple, app) and verifies the signature with
# OpenSSL 3. Exit 0 when nothing failed, 1 when a check failed, 2 on bad
# usage, a missing tool, or gh not signed in.
set -euo pipefail
for arg in "$@"; do
	case "$arg" in -h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done

REPO=dinooo13/pladder
TAP=dinooo13/homebrew-tap
# Sparkle refuses an update signed by another team, and the Accessibility and
# Microphone grants are keyed to it.
TEAM=V2KCT6R76J
BASE="https://github.com/$REPO/releases"

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: scripts/check-release.sh <version>, major.minor.patch" >&2
	exit 2
fi
VERSION="$1"
TAG="v$VERSION"

darwin=0
if [[ "$(uname -s)" == Darwin ]]; then darwin=1; fi
tools=(gh curl awk sed)
if [[ "$darwin" -eq 1 ]]; then tools+=(shasum xcrun spctl hdiutil codesign /usr/libexec/PlistBuddy); fi
for tool in "${tools[@]}"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "check-release.sh: $tool is missing" >&2
		exit 2
	fi
done
if command -v shasum >/dev/null 2>&1; then
	sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
elif command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
else
	echo "check-release.sh: neither shasum nor sha256sum is there" >&2
	exit 2
fi
if ! gh auth status >/dev/null 2>&1; then
	echo "check-release.sh: gh is not signed in (gh auth login)" >&2
	exit 2
fi

tmp=$(mktemp -d)
mounted=0
cleanup() {
	if [[ "$mounted" -eq 1 ]]; then
		hdiutil detach "$tmp/mnt" -quiet 2>/dev/null || hdiutil detach "$tmp/mnt" -force -quiet 2>/dev/null || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

passed=0
failed=0
skipped_draft=0
skipped_os=0
line() { printf '%s  %-15s  %s\n' "$1" "$2" "$3"; }
pass() { line PASS "$1" "$2"; passed=$((passed + 1)); }
fail() { line FAIL "$1" "$2"; failed=$((failed + 1)); }
skip_draft() { line SKIP "$1" "a draft; checked once it is published"; skipped_draft=$((skipped_draft + 1)); }
skip_os() { line SKIP "$1" "needs macOS"; skipped_os=$((skipped_os + 1)); }
# A tool's own words go to stderr, so stdout stays one line per check.
quote() { if [[ -s "$1" ]]; then sed 's/^/    /' "$1" >&2; fi; }
summary() {
	local title="Pladder $VERSION" parts=() joined
	if [[ "${draft:-false}" == true ]]; then title="$title is a draft"; fi
	if [[ "$failed" -gt 0 ]]; then parts+=("$failed failed"); fi
	if [[ "$passed" -gt 0 || "$failed" -eq 0 ]]; then parts+=("$passed passed"); fi
	if [[ "$skipped_draft" -gt 0 ]]; then parts+=("$skipped_draft skipped until it is published"); fi
	if [[ "$skipped_os" -gt 0 ]]; then parts+=("$skipped_os skipped on $(uname -s)"); fi
	joined=$(printf '%s, ' "${parts[@]}")
	echo
	echo "$title: ${joined%, }."
}

# release
if ! meta=$(gh release view "$TAG" -R "$REPO" --json tagName,name,isDraft,isPrerelease,url,assets \
	--jq '"\(.tagName)\t\(.isDraft)\t\(.isPrerelease)\t\(.url)\t\(.name)", (.assets[] | "asset\t\(.name)\t\(.digest)")' 2>"$tmp/err"); then
	fail release "no release $TAG in $REPO"
	quote "$tmp/err"
	summary
	exit 1
fi
IFS=$'\t' read -r tag_name draft prerelease url title <<<"$(head -n 1 <<<"$meta")"
problems=()
if [[ "$tag_name" != "$TAG" ]]; then problems+=("its tag is $tag_name"); fi
if [[ "$title" != "Pladder $VERSION" ]]; then problems+=("titled \"$title\", not \"Pladder $VERSION\""); fi
if [[ "$prerelease" == true ]]; then problems+=("marked a pre-release"); fi
if [[ ${#problems[@]} -gt 0 ]]; then
	fail release "$(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
	summary
	exit 1
fi
if [[ "$draft" == true ]]; then
	pass release "\"$title\", a draft, $url"
else
	pass release "\"$title\", $url"
fi

# latest
if [[ "$draft" == true ]]; then
	skip_draft latest
elif ! latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>"$tmp/err"); then
	fail latest "GitHub names no latest release"
	quote "$tmp/err"
elif [[ "$latest" == "$TAG" ]]; then
	pass latest "$TAG is the latest release"
else
	fail latest "the latest release is $latest, not $TAG"
fi

# assets
names=(Pladder.dmg Pladder.dmg.sha256 appcast.xml)
digest=""
missing=()
for name in "${names[@]}"; do
	row=$(awk -F '\t' -v n="$name" '$1 == "asset" && $2 == n { print; exit }' <<<"$meta")
	if [[ -z "$row" ]]; then
		missing+=("$name not attached")
		continue
	fi
	if [[ "$name" == Pladder.dmg ]]; then digest=$(cut -f 3 <<<"$row"); fi
	if [[ "$draft" == true ]]; then
		# A draft's files are not public yet; gh fetches them signed in.
		if ! gh release download "$TAG" -R "$REPO" --pattern "$name" --dir "$tmp" 2>"$tmp/err"; then
			missing+=("$name not downloaded")
			quote "$tmp/err"
		fi
	elif ! curl -fsSL --retry 2 -o "$tmp/$name" "$BASE/download/$TAG/$name" 2>"$tmp/err"; then
		missing+=("$name not downloaded from $BASE/download/$TAG/$name")
		quote "$tmp/err"
	fi
done
dmg="$tmp/Pladder.dmg"
have() { [[ -s "$tmp/$1" ]]; }
if [[ ${#missing[@]} -gt 0 ]]; then
	fail assets "$(printf '%s; ' "${missing[@]}" | sed 's/; $//')"
else
	pass assets "Pladder.dmg ($(($(wc -c <"$dmg"))) bytes), Pladder.dmg.sha256, appcast.xml"
fi
# Each check below names what it could not check, rather than being skipped.
needs() {
	local check="$1" absent=() name
	shift
	for name in "$@"; do have "$name" || absent+=("$name"); done
	if [[ ${#absent[@]} -gt 0 ]]; then
		fail "$check" "not checked: no $(printf '%s, ' "${absent[@]}" | sed 's/, $//')"
		return 1
	fi
}

# sha256
dmg_sha=""
if have Pladder.dmg; then dmg_sha=$(sha256 "$dmg"); fi
if needs sha256 Pladder.dmg Pladder.dmg.sha256; then
	listed=$(awk '{ print $1; exit }' "$tmp/Pladder.dmg.sha256")
	digest=${digest#sha256:}
	if [[ -z "$digest" || "$digest" == null ]]; then
		fail sha256 "GitHub gives no digest for Pladder.dmg"
	elif [[ "$listed" != "$dmg_sha" ]]; then
		fail sha256 "Pladder.dmg.sha256 says $listed, the DMG is $dmg_sha"
	elif [[ "$digest" != "$dmg_sha" ]]; then
		fail sha256 "GitHub's digest is $digest, the DMG is $dmg_sha"
	else
		pass sha256 "$dmg_sha"
	fi
fi

# appcast
build=""
if ! build=$(gh api graphql -f query="{repository(owner:\"${REPO%/*}\",name:\"${REPO#*/}\"){object(expression:\"$TAG^{commit}\"){... on Commit{history{totalCount}}}}}" \
	--jq '.data.repository.object.history.totalCount' 2>"$tmp/err") || [[ ! "$build" =~ ^[0-9]+$ ]]; then
	build=""
	quote "$tmp/err"
fi
signature=""
if needs appcast appcast.xml Pladder.dmg; then
	feed="$tmp/appcast.xml"
	field() { sed -n "s|.*<sparkle:$1>\\([^<]*\\)</sparkle:$1>.*|\\1|p" "$feed" | head -n 1; }
	items=$(grep -c '<item>' "$feed" || true)
	short=$(field shortVersionString)
	feed_build=$(field version)
	enclosure=$(sed -n 's|.*<enclosure [^>]*url="\([^"]*\)".*|\1|p' "$feed" | head -n 1)
	length=$(sed -n 's|.*<enclosure [^>]*length="\([0-9]*\)".*|\1|p' "$feed" | head -n 1)
	signature=$(sed -n 's|.*<enclosure [^>]*sparkle:edSignature="\([^"]*\)".*|\1|p' "$feed" | head -n 1)
	size=$(($(wc -c <"$dmg")))
	problems=()
	if [[ "$items" != 1 ]]; then problems+=("$items items, not one"); fi
	if [[ "$short" != "$VERSION" ]]; then problems+=("version \"$short\""); fi
	if [[ -z "$build" ]]; then
		problems+=("could not count the commits at $TAG")
	elif [[ "$feed_build" != "$build" ]]; then
		problems+=("build \"$feed_build\", but $TAG is commit $build")
	fi
	if [[ "$enclosure" != "$BASE/download/$TAG/Pladder.dmg" ]]; then problems+=("enclosure $enclosure"); fi
	if [[ "$length" != "$size" ]]; then problems+=("length $length, the DMG has $size bytes"); fi
	if [[ ${#problems[@]} -gt 0 ]]; then
		fail appcast "$(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
	else
		pass appcast "$VERSION, build $build, $size bytes, this release's DMG"
	fi
fi

# signature
if needs signature appcast.xml Pladder.dmg; then
	key=""
	if gh api "repos/$REPO/contents/Sources/Pladder/Resources/Info.plist?ref=$TAG" \
		-H 'Accept: application/vnd.github.raw' >"$tmp/Info.plist" 2>"$tmp/err"; then
		key=$(awk '
			/<key>SUPublicEDKey<\/key>/ { found = 1; sub(/.*<key>SUPublicEDKey<\/key>/, "") }
			found && /<string>/ { sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }
		' "$tmp/Info.plist")
	else
		quote "$tmp/err"
	fi
	if [[ -z "$key" ]]; then
		fail signature "no SUPublicEDKey in Sources/Pladder/Resources/Info.plist at $TAG"
	elif [[ -z "$signature" ]]; then
		fail signature "the appcast's enclosure has no sparkle:edSignature"
	elif [[ "$darwin" -eq 1 ]]; then
		# The check appcast.sh makes before it prints the feed.
		if xcrun swift - "$key" "$signature" "$dmg" >"$tmp/err" 2>&1 <<'SWIFT'
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard let key = Data(base64Encoded: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let data = FileManager.default.contents(atPath: arguments[3]),
      publicKey.isValidSignature(signature, for: data) else { exit(1) }
SWIFT
		then
			pass signature "verifies against SUPublicEDKey at $TAG (CryptoKit)"
		else
			fail signature "does not verify against SUPublicEDKey at $TAG"
			quote "$tmp/err"
		fi
	elif ! openssl version 2>/dev/null | grep -q '^OpenSSL 3'; then
		fail signature "no verifier: on Linux this needs OpenSSL 3, found $(openssl version 2>/dev/null || echo none)"
	else
		# An Ed25519 SubjectPublicKeyInfo is this fixed DER prefix and the raw key.
		{ printf '\060\052\060\005\006\003\053\145\160\003\041\000'; base64 -d <<<"$key"; } >"$tmp/key.der"
		base64 -d <<<"$signature" >"$tmp/signature.bin"
		if openssl pkeyutl -verify -pubin -inkey "$tmp/key.der" -keyform DER -rawin \
			-in "$dmg" -sigfile "$tmp/signature.bin" >"$tmp/err" 2>&1; then
			pass signature "verifies against SUPublicEDKey at $TAG (OpenSSL)"
		else
			fail signature "does not verify against SUPublicEDKey at $TAG"
			quote "$tmp/err"
		fi
	fi
fi

# gatekeeper, staple, app
if [[ "$darwin" -eq 0 ]]; then
	skip_os gatekeeper
	skip_os staple
	skip_os app
else
	if needs gatekeeper Pladder.dmg; then
		if spctl -a -vvv -t open --context context:primary-signature "$dmg" >"$tmp/err" 2>&1; then
			pass gatekeeper "accepted, $(sed -n 's/^source=//p' "$tmp/err")"
		else
			fail gatekeeper "spctl rejects the DMG"
			quote "$tmp/err"
		fi
	fi
	if needs staple Pladder.dmg; then
		if xcrun stapler validate "$dmg" >"$tmp/err" 2>&1; then
			pass staple "the notarisation ticket is stapled"
		else
			fail staple "stapler validate fails"
			quote "$tmp/err"
		fi
	fi
	if needs app Pladder.dmg; then
		mkdir "$tmp/mnt"
		if ! hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$tmp/mnt" "$dmg" >"$tmp/err" 2>&1; then
			fail app "the DMG does not mount"
			quote "$tmp/err"
		else
			mounted=1
			app="$tmp/mnt/Pladder.app"
			plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist" 2>/dev/null || true; }
			team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true; }
			app_version=$(plist CFBundleShortVersionString)
			app_build=$(plist CFBundleVersion)
			app_team=$(team "$app")
			dmg_team=$(team "$dmg")
			problems=()
			if [[ ! -d "$app" ]]; then problems+=("no Pladder.app in the DMG"); fi
			if [[ "$app_version" != "$VERSION" ]]; then problems+=("version \"$app_version\""); fi
			if [[ -z "$build" || "$app_build" != "$build" ]]; then problems+=("build \"$app_build\", not ${build:-the commit count}"); fi
			if [[ "$app_team" != "$TEAM" ]]; then problems+=("the app's team is \"$app_team\", not $TEAM"); fi
			if [[ "$dmg_team" != "$TEAM" ]]; then problems+=("the DMG's team is \"$dmg_team\", not $TEAM"); fi
			if [[ ${#problems[@]} -gt 0 ]]; then
				fail app "$(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
			else
				pass app "Pladder.app $app_version ($app_build), the app and the DMG by team $TEAM"
			fi
			if hdiutil detach "$tmp/mnt" -quiet >"$tmp/err" 2>&1; then mounted=0; else quote "$tmp/err"; fi
		fi
	fi
fi

# cask
if [[ "$draft" == true ]]; then
	skip_draft cask
else
	sha=${digest#sha256:}
	if [[ -z "$sha" || "$sha" == null ]]; then sha=$dmg_sha; fi
	if ! gh api "repos/$TAP/contents/Casks/pladder.rb" -H 'Accept: application/vnd.github.raw' >"$tmp/pladder.rb" 2>"$tmp/err"; then
		fail cask "no Casks/pladder.rb in $TAP"
		quote "$tmp/err"
	elif ! grep -qF "version \"$VERSION\"" "$tmp/pladder.rb"; then
		fail cask "$TAP's cask is $(sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$tmp/pladder.rb" | head -n 1), not $VERSION"
	elif [[ -z "$sha" || "$sha" == null ]]; then
		fail cask "not checked: no SHA-256 of the DMG"
	elif ! grep -qF "sha256 \"$sha\"" "$tmp/pladder.rb"; then
		fail cask "$TAP's cask names $VERSION with another SHA-256"
	else
		pass cask "$TAP names $VERSION and its SHA-256"
	fi
fi

# latest-download
if [[ "$draft" == true ]]; then
	skip_draft latest-download
else
	problems=()
	for name in Pladder.dmg appcast.xml; do
		target=$(curl -sSI -o /dev/null -w '%{redirect_url}' "$BASE/latest/download/$name" 2>"$tmp/err") || quote "$tmp/err"
		if [[ "$target" != "$BASE/download/$TAG/$name" ]]; then problems+=("$name goes to ${target:-nowhere}"); fi
	done
	if [[ ${#problems[@]} -gt 0 ]]; then
		fail latest-download "$(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
	else
		pass latest-download "Pladder.dmg and appcast.xml resolve to $TAG"
	fi
fi

summary
if [[ "$failed" -gt 0 ]]; then exit 1; fi
