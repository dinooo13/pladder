#!/usr/bin/env bash
# Builds Pladder in release and wraps the executable in dist/Pladder.app.
#
# The app bundle (not a bare binary) is what gives us a stable bundle ID and
# signature, which macOS needs to remember the Accessibility and Microphone
# grants across launches.
#
# Usage: scripts/bundle.sh [--run] [--install]
#   --run              launch dist/Pladder.app when done
#   --install          copy the app to /Applications (replacing an old copy)
#   SCRATCH=<dir>      optional swift build --scratch-path
#   CODESIGN_IDENTITY  signing identity; auto-detected, "-" forces ad-hoc
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH="${SCRATCH:-.build}"
RUN=0
INSTALL=0
for arg in "$@"; do
	case "$arg" in
	--run) RUN=1 ;;
	--install) INSTALL=1 ;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

APP="$ROOT/dist/Pladder.app"
CONTENTS="$APP/Contents"

# Info.plist lives under Sources/Pladder/Resources and is excluded from the
# SwiftPM resource bundle in Package.swift; it is copied straight into the app.
PLIST="$ROOT/Sources/Pladder/Resources/Info.plist"

swift build -c release --product Pladder --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --product Pladder --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/Pladder" "$CONTENTS/MacOS/Pladder"
cp "$PLIST" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
# App icon, rendered by scripts/make-icon.swift and packed with iconutil.
cp "$ROOT/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# SwiftPM emits one .bundle per target that declares resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$CONTENTS/Resources/"
done

# The String Catalogs compile into de.lproj/<Table>.strings inside those
# bundles. A nested bundle alone is ignored: macOS picks the app's language
# from the main bundle, which with a bare Info.plist has only English, so the
# German strings would never be reached. Merging the lproj folders into the
# app's own Resources both declares the languages and puts the tables where
# Bundle.main looks, which is why no code names a bundle.
for lproj in "$BIN_DIR"/*.bundle/Contents/Resources/*.lproj; do
	ditto "$lproj" "$CONTENTS/Resources/$(basename "$lproj")"
done
shopt -u nullglob

# Sign with a real certificate when one is available. An ad-hoc signature
# changes with every build, and macOS keys Accessibility and Microphone
# permission on the signature, so the user would have to re-grant both after
# each rebuild. A developer certificate gives a stable identity instead.
# Override with CODESIGN_IDENTITY=- to force ad-hoc, or set it to a specific
# identity name or hash.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
	CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
		| grep -E '"(Developer ID Application|Apple Development)' \
		| head -1 | sed -E 's/^[^"]*"([^"]+)".*$/\1/')
	CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
fi
echo "Signing with: $CODESIGN_IDENTITY"
codesign --force --sign "$CODESIGN_IDENTITY" \
	--entitlements "$ROOT/scripts/Pladder.entitlements" \
	--options runtime \
	--timestamp=none \
	"$APP"

echo "Built $APP"

if [[ "$INSTALL" -eq 1 ]]; then
	pkill -x Pladder 2>/dev/null || true
	rm -rf /Applications/Pladder.app
	cp -R "$APP" /Applications/Pladder.app
	APP=/Applications/Pladder.app
	echo "Installed $APP"
fi

if [[ "$RUN" -eq 1 ]]; then
	open "$APP"
fi
