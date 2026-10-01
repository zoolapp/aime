#!/usr/bin/env bash
# Downloads the pinned librime prebuilt release, verifies sha256 and
# assembles Vendor/CRime.xcframework + Vendor/librime/{lib,plugins,share}.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
LOCK="$VENDOR/librime.lock"
# shellcheck disable=SC1090
eval "$(grep -E '^LIBRIME_(VERSION|COMMIT)=' "$LOCK")"

BASE="https://github.com/rime/librime/releases/download/${LIBRIME_VERSION}"
ENGINE="rime-${LIBRIME_COMMIT}-macOS-universal.tar.bz2"
DEPS="rime-deps-${LIBRIME_COMMIT}-macOS-universal.tar.bz2"
CACHE="$VENDOR/.cache"
OUT="$VENDOR/librime"
XCF="$ROOT/Packages/AIMEKit/Frameworks/CRime.xcframework"

mkdir -p "$CACHE"
for f in "$ENGINE" "$DEPS"; do
  if [[ ! -f "$CACHE/$f" ]]; then
    echo "==> downloading $f"
    curl -fL --retry 3 -o "$CACHE/$f.part" "$BASE/$f"
    mv "$CACHE/$f.part" "$CACHE/$f"
  fi
done

echo "==> verifying sha256"
(cd "$CACHE" && grep -E '^[0-9a-f]{64}  ' "$LOCK" | shasum -a 256 -c -)

if [[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$LIBRIME_COMMIT" && -d "$XCF" ]]; then
  echo "==> librime $LIBRIME_VERSION ($LIBRIME_COMMIT) already assembled"
  exit 0
fi

echo "==> extracting"
rm -rf "$OUT" "$XCF" "$VENDOR/.stage"
STAGE="$VENDOR/.stage"
mkdir -p "$STAGE" "$OUT/lib" "$OUT/share"
tar -xjf "$CACHE/$ENGINE" -C "$STAGE"
tar -xjf "$CACHE/$DEPS" -C "$STAGE"

cp -L "$STAGE/dist/lib/librime.1.dylib" "$OUT/lib/"
cp -R "$STAGE/dist/lib/rime-plugins" "$OUT/lib/rime-plugins"
cp -RL "$STAGE/share/opencc" "$OUT/share/opencc"
cp -R "$STAGE/dist/bin" "$OUT/bin"
cp "$STAGE/version-info.txt" "$OUT/version-info.txt"

# Headers + module map for Swift (module CRime).
HDR="$STAGE/headers"
mkdir -p "$HDR"
cp "$STAGE/dist/include/rime_api.h" "$STAGE/dist/include/rime_api_stdbool.h" \
   "$STAGE/dist/include/rime_levers_api.h" "$HDR/"
cat > "$HDR/CRime.h" <<'H'
#include "rime_api_stdbool.h"
#include "rime_api.h"
#include "rime_levers_api.h"
H
cat > "$HDR/module.modulemap" <<'M'
module CRime {
  umbrella header "CRime.h"
  export *
}
M

echo "==> building CRime.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/lib/librime.1.dylib" -headers "$HDR" \
  -output "$XCF" >/dev/null

rm -rf "$STAGE"
echo "$LIBRIME_COMMIT" > "$OUT/.stamp"
echo "==> done: $XCF"
