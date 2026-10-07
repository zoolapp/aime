#!/usr/bin/env bash
# Finishes a release whose notarization was still in progress when CI ended
# (scripts/release.sh wrote NOTARY_PENDING.txt). Once Apple accepts every submission it
# staples the tickets into the pkg and the app inside the zip, recomputes SHA256SUMS,
# rewrites and re-signs latest.json and latest-beta.json (AIME_MANIFEST_KEY, from .env).
#
#   bash scripts/finish-notarization.sh <artefact-dir> [--publish]
#
# <artefact-dir> holds the CI artefact (gh run download <id> -R zoolapp/aime -D <dir>).
# --publish replaces the GitHub Release assets (same tag) and the files on R2
# (zool-assets/aime/releases/<version>/ and aime/latest.json[.sig]).
# Exit 3 while a submission is still in progress.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(cd "${1:?usage: finish-notarization.sh <artefact-dir> [--publish]}" && pwd)"
PUBLISH="${2:-}"
[[ -f "$ROOT/.env" ]] && { set -a; . "$ROOT/.env"; set +a; }
: "${AIME_NOTARY_KEY_PATH:?}" "${AIME_NOTARY_KEY_ID:?}" "${AIME_NOTARY_ISSUER_ID:?}" "${AIME_MANIFEST_KEY:?}"
[[ "$AIME_NOTARY_KEY_PATH" = /* ]] || AIME_NOTARY_KEY_PATH="$ROOT/$AIME_NOTARY_KEY_PATH"
NOTARY=(--key "$AIME_NOTARY_KEY_PATH" --key-id "$AIME_NOTARY_KEY_ID" --issuer "$AIME_NOTARY_ISSUER_ID")

MANIFEST="$DIR/latest-beta.json"
[[ -f "$MANIFEST" ]] || MANIFEST="$DIR/latest.json"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
PKG="$DIR/AIME-$VERSION.pkg" ZIP="$DIR/AIME-$VERSION.zip" SRC="$DIR/AIME-$VERSION-source.tar.gz"

if [[ -f "$DIR/NOTARY_PENDING.txt" ]]; then
  while IFS=$'\t' read -r file id; do
    status="$(xcrun notarytool info "$id" "${NOTARY[@]}" --output-format json | plutil -extract status raw -o - -)"
    echo "$file ($id): $status"
    case "$status" in
      Accepted) ;;
      "In Progress") echo "still in progress, try again later"; exit 3 ;;
      *) xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true; exit 1 ;;
    esac
  done < "$DIR/NOTARY_PENDING.txt"
fi

xcrun stapler staple "$PKG" && xcrun stapler validate "$PKG"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
xcrun stapler staple "$WORK/AIME.app" && xcrun stapler validate "$WORK/AIME.app"
rm -f "$ZIP" && ditto -c -k --keepParent "$WORK/AIME.app" "$ZIP"
spctl --assess --type install --verbose=2 "$PKG"

(cd "$DIR" && shasum -a 256 "$(basename "$PKG")" "$(basename "$ZIP")" "$(basename "$SRC")" > SHA256SUMS.txt)
python3 - "$DIR" "$VERSION" "$MANIFEST" <<'PY'
import hashlib, json, os, sys
out, version, path = sys.argv[1:4]
manifest = json.load(open(path))
for kind in ("pkg", "zip", "source"):
    entry = manifest["files"][kind]
    data = open(os.path.join(out, entry["name"]), "rb").read()
    entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
manifest["prerelease"] = "-" in version
if "-" in version:
    for stale in ("latest.json", "latest.json.sig"):
        stale_path = os.path.join(out, stale)
        if os.path.exists(stale_path): os.remove(stale_path)
for name in (["latest-beta.json"] if "-" in version else ["latest.json", "latest-beta.json"]):
    with open(os.path.join(out, name), "w") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
PY
for manifest in latest.json latest-beta.json; do
  [[ -f "$DIR/$manifest" ]] || continue
  AIME_MANIFEST_KEY="$AIME_MANIFEST_KEY" swift "$ROOT/scripts/sign-manifest.swift" sign "$DIR/$manifest"
done
echo notarized > "$DIR/SIGNING_STATUS"
rm -f "$DIR/NOTARY_PENDING.txt"
cat "$DIR/SHA256SUMS.txt"

[[ "$PUBLISH" == --publish ]] || { echo "stapled; re-run with --publish to replace the release files"; exit 0; }
# A late notarization of an older release must not roll an update channel back, so each
# manifest is compared with its live copy. Only a 404 for latest-beta.json (no beta
# published yet) counts as absent; any other failure aborts before anything is uploaded.
newer_live() {  # <manifest> → prints the live version when it is newer than $VERSION
  local body live code
  body="$(curl -sS -w '\n%{http_code}' "https://get.zool.app/aime/$1" 2>/dev/null)" \
    || { echo "cannot reach the live $1; not touching it" >&2; return 1; }
  code="${body##*$'\n'}" body="${body%$'\n'*}"
  [[ "$code" == 404 && "$1" == latest-beta.json ]] && return 0
  [[ "$code" == 200 ]] || { echo "cannot read the live $1 (HTTP $code); not touching it" >&2; return 1; }
  live="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<<"$body" 2>/dev/null)" \
    || { echo "cannot parse the live $1; not touching it" >&2; return 1; }
  python3 - "$VERSION" "$live" <<'PY' || echo "$live"
import re, sys
def key(v):  # 1.2.3 > 1.2.3-beta.1; numeric parts compare as numbers
    core, _, pre = v.partition("-")
    nums = tuple(int(x) for x in core.split("."))
    return nums + ((1,) if not pre else (0,) + tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.]", pre)),)
sys.exit(0 if key(sys.argv[1]) >= key(sys.argv[2]) else 1)
PY
}
STABLE_NEWER="" BETA_NEWER=""  # bash 3.2 (macOS) has no associative arrays
if [[ -f "$DIR/latest.json" ]]; then STABLE_NEWER="$(newer_live latest.json)" || exit 1; fi
if [[ -f "$DIR/latest-beta.json" ]]; then BETA_NEWER="$(newer_live latest-beta.json)" || exit 1; fi
gh release upload "v$VERSION" -R zoolapp/aime --clobber "$PKG" "$ZIP" "$SRC" "$DIR/SHA256SUMS.txt"
gh release edit "v$VERSION" -R zoolapp/aime --title "AIME $VERSION"
for f in "$PKG" "$ZIP" "$SRC" "$DIR/SHA256SUMS.txt"; do
  (cd "$ROOT/../zool-get" && npx wrangler r2 object put "zool-assets/aime/releases/$VERSION/$(basename "$f")" --file "$f" --remote >/dev/null)
done
for manifest in latest.json latest-beta.json; do
  [[ -f "$DIR/$manifest" ]] || continue
  newer="$STABLE_NEWER"; [[ "$manifest" == latest-beta.json ]] && newer="$BETA_NEWER"
  if [[ -n "$newer" ]]; then
    echo "$manifest stays at $newer (newer)"
    continue
  fi
  (cd "$ROOT/../zool-get" && npx wrangler r2 object put "zool-assets/aime/$manifest.sig" --file "$DIR/$manifest.sig" \
    --content-type text/plain --remote >/dev/null && npx wrangler r2 object put "zool-assets/aime/$manifest" \
    --file "$DIR/$manifest" --content-type application/json --remote >/dev/null)
done
echo "published $VERSION (notarized)"
