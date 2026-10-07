#!/usr/bin/env bash
# Offline manifest generation/signing; never uploads, builds or notarizes anything.
# Usage: write-update-manifests.sh <artefact-dir> <version> <build> <status>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?artefact directory required}"
VERSION="${2:?version required}"
BUILD="${3:?build required}"
STATUS="${4:?signing status required}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "invalid build" >&2; exit 1; }
# Remove stale manifests if the directory is reused for another channel.
rm -f "$OUT/latest.json" "$OUT/latest.json.sig" "$OUT/latest-beta.json" "$OUT/latest-beta.json.sig"
python3 - "$OUT" "$VERSION" "$BUILD" "$STATUS" <<'PY'
import hashlib, json, os, sys, datetime
out, version, build, status = sys.argv[1:5]
def entry(name):
    path = os.path.join(out, name)
    return {"name": name, "size": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}
manifest = {
    "product": "aime", "version": version, "build": int(build),
    "date": datetime.date.today().isoformat(), "prerelease": "-" in version or status != "notarized",
    "minimumSystemVersion": "26.0", "default": "pkg",
    "files": {"pkg": entry(f"AIME-{version}.pkg"), "zip": entry(f"AIME-{version}.zip"),
              "source": entry(f"AIME-{version}-source.tar.gz"), "sums": {"name": "SHA256SUMS.txt"}},
}
names = ["latest-beta.json"] if "-" in version else ["latest.json", "latest-beta.json"]
for name in names:
    with open(os.path.join(out, name), "w") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
PY
for name in latest.json latest-beta.json; do
  [[ -f "$OUT/$name" ]] || continue
  if [[ -n "${AIME_MANIFEST_KEY:-}" ]]; then
    swift "$ROOT/scripts/sign-manifest.swift" sign "$OUT/$name"
  elif [[ "$STATUS" == notarized || "$STATUS" == pending ]]; then
    echo "AIME_MANIFEST_KEY is required to sign $name for an official release" >&2
    exit 1
  fi
done
