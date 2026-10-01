#!/usr/bin/env bash
# Captures AIME Settings panes in light and dark mode into .ui-acceptance/<date>/.
#   bash scripts/ui-shots.sh [pane ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/DerivedData/Build/Products/Debug/AIME Settings.app}"
PROCESS_NAME="${AIME_UI_PROCESS_NAME:-AIME Settings}"
OUT="${AIME_UI_OUT:-$ROOT/.ui-acceptance/$(date +%Y-%m-%d)}"
mkdir -p "$OUT"
# Never point automation at the real workspace: screenshots run against a throwaway
# copy (config only — no userdb, no build/ except what the UI reads).
SANDBOX="$(mktemp -d -t aime-ui)"
SRC="${AIME_UI_SOURCE:-$HOME/Library/AIME/Rime}"
if [[ -d "$SRC" ]]; then
  rsync -a --exclude '*.userdb' --exclude 'sync' --exclude '*.gram' --exclude 'cn_dicts' "$SRC/" "$SANDBOX/"
fi
# Usage statistics are sandboxed the same way (optionally seeded from AIME_UI_STATS_SOURCE).
STATS="$(mktemp -d -t aime-ui-stats)"
if [[ -n "${AIME_UI_STATS_SOURCE:-}" && -d "$AIME_UI_STATS_SOURCE" ]]; then rsync -a "$AIME_UI_STATS_SOURCE/" "$STATS/"; fi
CREDENTIALS="$STATS/credentials.json"
# A synthetic non-empty value skips legacy Keychain migration during UI capture.
printf '%s\n' '{"openai-compatible":"ui-fixture-no-api-key"}' > "$CREDENTIALS"
chmod 600 "$CREDENTIALS"
trap 'rm -rf "$SANDBOX" "$STATS"' EXIT
PANES=("$@"); [[ ${#PANES[@]} -gt 0 ]] || PANES=(overview appearance schemas spelling dictionaries phrases snippets stats ai advanced)
WINDOW_ID_SCRIPT="$(mktemp -t winid).swift"
cat > "$WINDOW_ID_SCRIPT" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let owner = CommandLine.arguments[1]
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}
SWIFT
WINDOW_ID_BIN="$(mktemp -t winid-bin)"
swiftc -O "$WINDOW_ID_SCRIPT" -o "$WINDOW_ID_BIN"
for mode in light dark; do
  for pane in "${PANES[@]}"; do
    pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
    sleep 0.5
    open -n --env AIME_USER_DIR="$SANDBOX" --env AIME_STATS_DIR="$STATS" --env AIME_CREDENTIALS_FILE="$CREDENTIALS" "$APP" --args --pane "$pane" --appearance "$mode" ${AIME_UI_ARGS:-}
    # Wait for the window instead of a fixed delay (first launch of a new build is slow).
    wid=""
    for _ in $(seq 1 15); do
      sleep 1
      wid="$("$WINDOW_ID_BIN" "$PROCESS_NAME" 2>/dev/null || true)"
      [[ -n "$wid" ]] && break
    done
    if [[ -z "$wid" ]]; then
      # The first launch of a freshly signed build sometimes comes up without its window.
      pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
      sleep 1
      open -n --env AIME_USER_DIR="$SANDBOX" --env AIME_STATS_DIR="$STATS" --env AIME_CREDENTIALS_FILE="$CREDENTIALS" "$APP" --args --pane "$pane" --appearance "$mode" ${AIME_UI_ARGS:-}
      for _ in $(seq 1 15); do
        sleep 1
        wid="$("$WINDOW_ID_BIN" "$PROCESS_NAME" 2>/dev/null || true)"
        [[ -n "$wid" ]] && break
      done
    fi
    [[ -n "$wid" ]] || { echo "window for $pane ($mode) did not appear" >&2; exit 1; }
    sleep "${AIME_UI_SETTLE:-1.5}"
    screencapture -l "$wid" -o "$OUT/settings-$pane-$mode.png"
    # Minimum window size (the native counterpart of a "mobile" check).
    osascript -e 'on run argv' -e 'tell application "System Events" to tell process (item 1 of argv) to set size of window 1 to {900, 620}' -e 'end run' "$PROCESS_NAME" >/dev/null 2>&1 || true
    sleep 0.8
    screencapture -l "$wid" -o "$OUT/settings-$pane-$mode-narrow.png"
    echo "captured $pane ($mode, default + narrow)"
  done
done
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
