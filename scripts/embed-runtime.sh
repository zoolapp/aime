#!/usr/bin/env bash
# Xcode post-build step for AIME.app: copies librime plugins next to librime.1.dylib
# and the assembled SharedSupport into the bundle.
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS" "$APP/Contents/SharedSupport"

if [[ ! -f "$FRAMEWORKS/librime.1.dylib" ]]; then
  cp -L "$ROOT/Vendor/librime/lib/librime.1.dylib" "$FRAMEWORKS/"
fi
rm -rf "$FRAMEWORKS/rime-plugins"
cp -R "$ROOT/Vendor/librime/lib/rime-plugins" "$FRAMEWORKS/rime-plugins"

if [[ -d "$ROOT/build/SharedSupport" ]]; then
  rsync -a --delete "$ROOT/build/SharedSupport/" "$APP/Contents/SharedSupport/"
else
  echo "warning: build/SharedSupport missing — run scripts/fetch-dicts.sh" >&2
fi

# Validate pinned inputs and embed their audited license texts before code signing.
python3 "$ROOT/scripts/embed-license-materials.py" --app "$APP"

# Re-sign nested code with the app's identity (plugins are loaded via dlopen).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
TIMESTAMP=--timestamp
[[ "$IDENTITY" == "-" ]] && TIMESTAMP=--timestamp=none
for lib in "$FRAMEWORKS"/librime.1.dylib "$FRAMEWORKS"/rime-plugins/*.dylib; do
  # The timestamp service is sometimes unreachable; this intermediate signature is
  # replaced by build-app.sh anyway, so fall back to an untimestamped one.
  codesign --force --options runtime --sign "$IDENTITY" "$TIMESTAMP" "$lib" >/dev/null 2>&1 \
    || codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$lib" >/dev/null
done
