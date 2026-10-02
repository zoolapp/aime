#!/usr/bin/env bash
# Finishes a release whose notarization was still in progress when CI ended
# (scripts/release.sh wrote NOTARY_PENDING.txt). Once Apple accepts every submission it
# staples the tickets into the pkg and the app inside the zip, recomputes SHA256SUMS,
# rewrites and re-signs latest.json (AIME_MANIFEST_KEY, from .env).
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

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$DIR/latest.json")"
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
python3 - "$DIR" "$VERSION" <<'PY'
import hashlib, json, os, sys
out, version = sys.argv[1:3]
path = os.path.join(out, "latest.json")
manifest = json.load(open(path))
for kind in ("pkg", "zip", "source"):
    entry = manifest["files"][kind]
    data = open(os.path.join(out, entry["name"]), "rb").read()
    entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
manifest["prerelease"] = "-" in version
json.dump(manifest, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
AIME_MANIFEST_KEY="$AIME_MANIFEST_KEY" swift "$ROOT/scripts/sign-manifest.swift" sign "$DIR/latest.json"
echo notarized > "$DIR/SIGNING_STATUS"
rm -f "$DIR/NOTARY_PENDING.txt"
cat "$DIR/SHA256SUMS.txt"

[[ "$PUBLISH" == --publish ]] || { echo "stapled; re-run with --publish to replace the release files"; exit 0; }
NEWER_LIVE=""
# A late notarization of an older release must not roll the update channel back.
LIVE="$(curl -fsS https://get.zool.app/aime/latest.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" \
  || { echo "cannot read the live latest.json; not touching it" >&2; exit 1; }
if ! python3 - "$VERSION" "$LIVE" <<'PY'
import re, sys
def key(v):  # 1.2.3 > 1.2.3-beta.1; numeric parts compare as numbers
    core, _, pre = v.partition("-")
    nums = tuple(int(x) for x in core.split("."))
    return nums + ((1,) if not pre else (0,) + tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.]", pre)),)
sys.exit(0 if key(sys.argv[1]) >= key(sys.argv[2]) else 1)
PY
then
  NEWER_LIVE="$LIVE"
fi
gh release upload "v$VERSION" -R zoolapp/aime --clobber "$PKG" "$ZIP" "$SRC" "$DIR/SHA256SUMS.txt"
gh release edit "v$VERSION" -R zoolapp/aime --title "AIME $VERSION"
for f in "$PKG" "$ZIP" "$SRC" "$DIR/SHA256SUMS.txt"; do
  (cd "$ROOT/../zool-get" && npx wrangler r2 object put "zool-assets/aime/releases/$VERSION/$(basename "$f")" --file "$f" --remote >/dev/null)
done
if [[ -n "$NEWER_LIVE" ]]; then
  echo "published $VERSION files (notarized); latest.json stays at $NEWER_LIVE (newer)"
  exit 0
fi
(cd "$ROOT/../zool-get" && npx wrangler r2 object put zool-assets/aime/latest.json.sig --file "$DIR/latest.json.sig" \
  --content-type text/plain --remote >/dev/null && npx wrangler r2 object put zool-assets/aime/latest.json \
  --file "$DIR/latest.json" --content-type application/json --remote >/dev/null)
echo "published $VERSION (notarized)"
