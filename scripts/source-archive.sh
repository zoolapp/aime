#!/usr/bin/env bash
# Builds AIME-<version>-source.tar.gz, the corresponding source for one release:
#   aime/                AIME at the release commit (git archive, MIT)
#   upstream/librime/    librime at the pinned version (BSD-3-Clause)
#   upstream/librime-*/  the three native plugins at the commits in
#                        licenses/native-plugins/manifest.json (lua, predict: BSD-3-Clause;
#                        octagram: GPL-3.0)
#   upstream/rime-ice/   the pinned rime-ice release asset as shipped (GPL-3.0)
#   SOURCES.txt          where each part came from, with SHA-256 of every download
#
# The installer contains GPL-3.0 components, so every release attaches this archive.
# Usage: bash scripts/source-archive.sh <version> <out-dir> [<commit>]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/source-archive.sh <version> <out-dir> [<commit>]}"
OUT="${2:?usage: scripts/source-archive.sh <version> <out-dir> [<commit>]}"
COMMIT="${3:-HEAD}"
NAME="AIME-$VERSION-source"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DEST="$WORK/$NAME"
mkdir -p "$DEST/aime" "$DEST/upstream" "$OUT"

fetch() {  # <url> <file>: bounded download, prints sha256
  curl -fsSL --retry 3 --max-time 300 -o "$2" "$1"
  shasum -a 256 "$2" | cut -d' ' -f1
}

git -C "$ROOT" archive --format=tar "$COMMIT" | tar -x -C "$DEST/aime"
{
  echo "AIME $VERSION corresponding source"
  echo "aime/: git $(git -C "$ROOT" rev-parse "$COMMIT")"
} > "$DEST/SOURCES.txt"

eval "$(grep -E '^LIBRIME_(VERSION|COMMIT)=[0-9A-Za-z.]+$' "$ROOT/Vendor/librime.lock")"
sha="$(fetch "https://codeload.github.com/rime/librime/tar.gz/refs/tags/$LIBRIME_VERSION" "$WORK/librime.tar.gz")"
mkdir -p "$DEST/upstream/librime" && tar -xzf "$WORK/librime.tar.gz" -C "$DEST/upstream/librime" --strip-components 1
echo "upstream/librime/: rime/librime $LIBRIME_VERSION ($LIBRIME_COMMIT), sha256 $sha" >> "$DEST/SOURCES.txt"

while IFS=$'\t' read -r component repo commit; do
  sha="$(fetch "https://codeload.github.com/${repo#https://github.com/}/tar.gz/$commit" "$WORK/$component.tar.gz")"
  mkdir -p "$DEST/upstream/$component" && tar -xzf "$WORK/$component.tar.gz" -C "$DEST/upstream/$component" --strip-components 1
  echo "upstream/$component/: $repo @ $commit, sha256 $sha" >> "$DEST/SOURCES.txt"
done < <(python3 -c '
import json, sys
for c in json.load(open(sys.argv[1]))["components"]:
    print(c["component"], c["repository"], c["sourceCommit"], sep="\t")
' "$ROOT/licenses/native-plugins/manifest.json")

read -r url expected file < <(python3 -c '
import json, sys
pkg = next(p for p in json.load(open(sys.argv[1]))["packages"] if p["id"] == "rime-ice")
s = pkg["source"]
print("https://github.com/%s/releases/download/%s/%s" % (s["repo"], s["tag"], s["asset"]), pkg["sha256"], "rime-ice-%s-%s" % (s["tag"], s["asset"]))
' "$ROOT/dicts/registry.json")
mkdir -p "$DEST/upstream/rime-ice"
sha="$(fetch "$url" "$DEST/upstream/rime-ice/$file")"
[[ "$sha" == "$expected" ]] || { echo "rime-ice checksum mismatch: $sha" >&2; exit 1; }
echo "upstream/rime-ice/$file: $url, sha256 $sha" >> "$DEST/SOURCES.txt"

COPYFILE_DISABLE=1 tar -czf "$OUT/$NAME.tar.gz" -C "$WORK" "$NAME"
echo "==> $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
