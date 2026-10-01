#!/usr/bin/env bash
# Produces dist/AIME-<version>.pkg: installs AIME.app to /Library/Input Methods (and
# AIME Settings.app to /Applications) and
# registers it for the installing user. Unsigned unless AIME_INSTALLER_IDENTITY
# (a "Developer ID Installer" certificate) is set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"

[[ "${SKIP_BUILD:-0}" == 1 ]] || AIME_REQUIRE_TIMESTAMP=$([[ "${AIME_SIGN_IDENTITY:--}" == "-" ]] && echo 0 || echo 1) bash scripts/build-app.sh

STAGE="$ROOT/build/pkg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$STAGE/root/Library/Input Methods" dist
ditto --noextattr --noqtn build/Release/AIME.app "$STAGE/root/Library/Input Methods/AIME.app"
# Settings also goes to /Applications so it is easy to find (Launchpad, Spotlight).
mkdir -p "$STAGE/root/Applications"
ditto --noextattr --noqtn "build/Release/AIME.app/Contents/Applications/AIME Settings.app" "$STAGE/root/Applications/AIME Settings.app"
# Extended attributes would be archived as ._* AppleDouble files in the payload.
xattr -cr "$STAGE/root"

COPYFILE_DISABLE=1 pkgbuild --root "$STAGE/root" --install-location / \
  --identifier app.zool.inputmethod.aime.pkg --version "$VERSION" \
  --scripts scripts/pkg/scripts "$STAGE/AIME-component.pkg" >/dev/null

cat > "$STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>AIME $VERSION</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="LICENSE"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="default"><line choice="aime"/></line></choices-outline>
  <choice id="default"/>
  <choice id="aime" visible="false"><pkg-ref id="app.zool.inputmethod.aime.pkg"/></choice>
  <pkg-ref id="app.zool.inputmethod.aime.pkg" version="$VERSION" onConclusion="none">AIME-component.pkg</pkg-ref>
</installer-gui-script>
XML
cp scripts/pkg/resources/*.html "$STAGE/"
# The installer's license page: what the package contains, then MIT and GPL-3.0 in full.
{
  cat scripts/pkg/LICENSE-header.txt
  printf '\n\n==== MIT License (AIME original code) ====\n\n'
  cat LICENSE
  printf '\n\n==== GNU General Public License v3.0 ====\n\n'
  cat licenses/native-plugins/librime-octagram.LICENSE.txt
} > "$STAGE/LICENSE"

SIGN_ARGS=()
[[ -n "${AIME_INSTALLER_IDENTITY:-}" ]] && SIGN_ARGS=(--sign "$AIME_INSTALLER_IDENTITY")
productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE" --package-path "$STAGE" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "dist/AIME-$VERSION.pkg" >/dev/null
rm -rf "$STAGE"
echo "==> dist/AIME-$VERSION.pkg ($(du -h "dist/AIME-$VERSION.pkg" | cut -f1))"
