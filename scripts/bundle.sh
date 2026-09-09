#!/usr/bin/env bash
# Builds SpeakUp in release and wraps the executable in dist/SpeakUp.app.
#
# The app bundle (not a bare binary) is what gives us a stable bundle ID and
# signature, which macOS needs to remember the Accessibility and Microphone
# grants across launches.
#
# Usage: scripts/bundle.sh [--run]
#   SCRATCH=<dir>  optional swift build --scratch-path
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH="${SCRATCH:-.build}"
RUN=0
for arg in "$@"; do
	case "$arg" in
	--run) RUN=1 ;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

APP="$ROOT/dist/SpeakUp.app"
CONTENTS="$APP/Contents"

# Info.plist lives under Sources/SpeakUp/Resources. SwiftPM forbids a resource
# literally named Info.plist, so the checked-in file is AppInfo.plist.
PLIST="$ROOT/Sources/SpeakUp/Resources/Info.plist"
[[ -f "$PLIST" ]] || PLIST="$ROOT/Sources/SpeakUp/Resources/AppInfo.plist"

swift build -c release --product SpeakUp --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --product SpeakUp --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/SpeakUp" "$CONTENTS/MacOS/SpeakUp"
cp "$PLIST" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# SwiftPM emits one .bundle per target that declares resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

codesign --force --sign - \
	--entitlements "$ROOT/scripts/SpeakUp.entitlements" \
	--options runtime \
	"$APP"

echo "Built $APP"

if [[ "$RUN" -eq 1 ]]; then
	open "$APP"
fi
