#!/usr/bin/env bash
# Exports the public tree of AIME (what github.com/zoolapp/aime publishes) from a commit,
# using an allowlist so internal process notes, review evidence and agent instructions
# never leave this repository. The result is scanned with gitleaks.
#
#   bash scripts/export-public.sh [<commit>] [<out-dir>]
#
# Defaults: HEAD, build/public-export. The output is a plain directory (no .git):
# initialise the public repository from it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="${1:-HEAD}"
OUT="${2:-$ROOT/build/public-export}"

# Paths published as they are (files or whole directories).
INCLUDE=(
  .editorconfig .gitignore .swiftlint.yml .github
  README.md README.zh.md LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md
  CONTRIBUTING.md CONTRIBUTING.zh.md CODE_OF_CONDUCT.md SECURITY.md
  project.yml Apps Packages SharedSupport config dicts licenses scripts Vendor
  assets/icon.png assets/screenshots assets/brand/aime/base-v1
  docs/architecture.md docs/decisions docs/privacy.md docs/rime-config-reference.md
  docs/releasing.md docs/release-checklist.md
  docs/license-packaging-verification.md docs/native-plugin-license-audit.md
)
# Removed again from the included directories: tooling output and design-process notes.
EXCLUDE=(
  Apps/AIMESettings/.impeccable
  Apps/AIMESettings/DESIGN.md
  assets/brand/aime/base-v1/paper-reference-provenance.json
)

rm -rf "$OUT"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -x -C "$STAGE"

for path in "${INCLUDE[@]}"; do
  [[ -e "$STAGE/$path" ]] || { echo "skip (not in $COMMIT): $path" >&2; continue; }
  mkdir -p "$OUT/$(dirname "$path")"
  cp -R "$STAGE/$path" "$OUT/$path"
done
for path in "${EXCLUDE[@]}"; do rm -rf "${OUT:?}/$path"; done
# Never publish local symlinks to agent instructions.
find "$OUT" -name CLAUDE.md -o -name AGENTS.md | xargs rm -f

files=$(find "$OUT" -type f | wc -l | tr -d ' ')
echo "exported $files files from $(git -C "$ROOT" rev-parse --short "$COMMIT") to $OUT"

if command -v gitleaks >/dev/null; then
  gitleaks dir "$OUT" --no-banner --redact --exit-code 1 && echo "gitleaks: no findings"
else
  echo "gitleaks not installed — scan the export before publishing" >&2
  exit 2
fi
