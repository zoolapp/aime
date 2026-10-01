#!/usr/bin/env bash
# Builds and assembles a complete, signed AIME.app at build/Release/AIME.app:
#   Contents/MacOS/AIME                      input method
#   Contents/Helpers/aime                    CLI (+ its resource bundle)
#   Contents/Applications/AIME Settings.app  settings
#   Contents/Frameworks/librime + rime-plugins, Contents/SharedSupport
# Used by install-dev.sh and package.sh. Signs ad-hoc unless AIME_SIGN_IDENTITY is set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"
IDENTITY="${AIME_SIGN_IDENTITY:--}"

cd "$ROOT"
[[ -d Packages/AIMEKit/Frameworks/CRime.xcframework ]] || bash scripts/fetch-librime.sh
[[ -f build/SharedSupport/default.yaml ]] || bash scripts/fetch-dicts.sh
# AIME's own data changes more often than the dictionaries: always refresh it.
ditto SharedSupport build/SharedSupport
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

echo "==> building apps ($CONFIG)"
xcodebuild -project AIME.xcodeproj -scheme AIME -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet
BUILT="$DERIVED/Build/Products/$CONFIG"

echo "==> building CLI"
swift build --package-path Packages/AIMEKit -c release --product aime >/dev/null
CLI_DIR="$(swift build --package-path Packages/AIMEKit -c release --show-bin-path)"

rm -rf "$OUT" && mkdir -p "$OUT"
APP="$OUT/AIME.app"
ditto "$BUILT/AIME.app" "$APP"
# Not Contents/MacOS: the file system is case-insensitive and "aime" would replace "AIME".
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Applications"
cp "$CLI_DIR/aime" "$APP/Contents/Helpers/aime"
ditto "$CLI_DIR/AIMEKit_AIMECore.bundle" "$APP/Contents/Helpers/AIMEKit_AIMECore.bundle"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Helpers/aime" 2>/dev/null || true
ditto "$BUILT/AIME Settings.app" "$APP/Contents/Applications/AIME Settings.app"

# Local builds are signed ad-hoc by default. Set AIME_SIGN_IDENTITY to a certificate
# hash to use a real identity — but make sure it is not revoked: macOS treats code
# signed with a revoked certificate as malware (kills it and moves the app to Trash).
echo "==> signing with: $IDENTITY"
TIMESTAMP=--timestamp
[[ "$IDENTITY" == "-" ]] && TIMESTAMP=--timestamp=none
# Development builds tolerate an unreachable timestamp service; release packaging sets
# AIME_REQUIRE_TIMESTAMP=1 (notarization needs secure timestamps).
sign() {
  codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@" 2>/dev/null && return 0
  [[ "${AIME_REQUIRE_TIMESTAMP:-0}" == 1 ]] && { echo "timestamp service unavailable" >&2; return 1; }
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"
}
for lib in "$APP"/Contents/Frameworks/librime.1.dylib "$APP"/Contents/Frameworks/rime-plugins/*.dylib; do sign "$lib"; done
sign "$APP/Contents/Helpers/AIMEKit_AIMECore.bundle"
sign --entitlements Apps/AIME/AIME.entitlements "$APP/Contents/Helpers/aime"
sign --entitlements Apps/AIMESettings/AIMESettings.entitlements "$APP/Contents/Applications/AIME Settings.app"
sign --entitlements Apps/AIME/AIME.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "==> built $APP"
