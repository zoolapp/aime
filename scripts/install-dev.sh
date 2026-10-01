#!/usr/bin/env bash
# Builds AIME and installs it for the current user into ~/Library/Input Methods,
# then registers and enables the input source. For a system-wide install use the
# package from scripts/package.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Input Methods"

bash "$ROOT/scripts/build-app.sh"

echo "==> installing to $DEST"
pkill -f "Input Methods/AIME.app/Contents/MacOS/AIME" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/AIME.app"
ditto "$ROOT/build/Release/AIME.app" "$DEST/AIME.app"
"$DEST/AIME.app/Contents/MacOS/AIME" --install || true
# A copy installed by the .pkg (/Library) has the same bundle id: macOS may launch
# either one and keeps showing cached icons. Development wants exactly one.
if [[ -d "/Library/Input Methods/AIME.app" ]]; then
  echo "warning: /Library/Input Methods/AIME.app (installed by the .pkg) also exists." >&2
  echo "         Two copies share one bundle id; remove one, e.g.:" >&2
  echo "         sudo rm -rf '/Library/Input Methods/AIME.app' '/Applications/AIME Settings.app'" >&2
fi
echo "==> done. If AIME is not selectable yet, add it in System Settings › Keyboard ›"
echo "    Input Sources (log out and back in once after the first install)."
echo "    CLI: \"$DEST/AIME.app/Contents/Helpers/aime\" doctor"
