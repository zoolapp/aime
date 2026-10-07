#!/usr/bin/env bash
# Temporary fixture files and an ephemeral signing key only. No cloud calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t aime-manifest-test)"
trap 'rm -rf "$WORK"' EXIT
umask 077
swift "$ROOT/scripts/sign-manifest.swift" keygen > "$WORK/key.txt"
AIME_MANIFEST_KEY="$(awk '/^private:/ {print $2}' "$WORK/key.txt")"
export AIME_MANIFEST_KEY
PUBLIC_KEY="$(awk '/^public:/ {print $2}' "$WORK/key.txt")"
for version in 0.2.0-beta.1 0.2.0; do
  for extension in pkg zip; do printf 'fixture\n' > "$WORK/AIME-$version.$extension"; done
  printf 'fixture\n' > "$WORK/AIME-$version-source.tar.gz"
  bash "$ROOT/scripts/write-update-manifests.sh" "$WORK" "$version" 3 notarized >/dev/null
  swift "$ROOT/scripts/sign-manifest.swift" verify "$WORK/latest-beta.json" "$PUBLIC_KEY"
  if [[ "$version" == *-beta.* ]]; then
    [[ ! -e "$WORK/latest.json" && ! -e "$WORK/latest.json.sig" ]]
  else
    cmp "$WORK/latest.json" "$WORK/latest-beta.json"
    swift "$ROOT/scripts/sign-manifest.swift" verify "$WORK/latest.json" "$PUBLIC_KEY"
  fi
  python3 - "$WORK/latest-beta.json" "$version" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
assert manifest['version'] == sys.argv[2]
assert manifest['prerelease'] == ('-' in sys.argv[2])
assert manifest['build'] == 3
for kind in ('pkg', 'zip', 'source'):
    entry = manifest['files'][kind]
    data = (path.parent / entry['name']).read_bytes()
    assert entry['sha256'] == hashlib.sha256(data).hexdigest()
    assert entry['size'] == len(data)
PY
done
# Reusing a stable artefact directory for beta cannot leave a stale stable manifest.
bash "$ROOT/scripts/write-update-manifests.sh" "$WORK" 0.2.0-beta.1 3 notarized >/dev/null
[[ ! -e "$WORK/latest.json" && ! -e "$WORK/latest.json.sig" ]]
# Official builds require signatures; tampering must invalidate the signature.
if AIME_MANIFEST_KEY='' bash "$ROOT/scripts/write-update-manifests.sh" "$WORK" 0.2.0 3 notarized > "$WORK/missing-key.log" 2>&1; then
  echo 'FAIL: unsigned official manifest accepted' >&2; exit 1
fi
bash "$ROOT/scripts/write-update-manifests.sh" "$WORK" 0.2.0 3 notarized >/dev/null
printf ' ' >> "$WORK/latest-beta.json"
if swift "$ROOT/scripts/sign-manifest.swift" verify "$WORK/latest-beta.json" "$PUBLIC_KEY" > "$WORK/tampered.log" 2>&1; then
  echo 'FAIL: tampered manifest accepted' >&2; exit 1
fi
# Exercise only the pure manifest-rewrite block of the finish script; no notary calls.
python3 - "$ROOT/scripts/finish-notarization.sh" "$WORK" <<'PYTEST'
import json, pathlib, sys
script, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
body = script.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
for version in ('0.2.0-beta.1', '0.2.0'):
    original = json.loads((root / 'latest.json').read_text())
    original.update(version=version, notes='preserve release notes', date='2026-10-01')
    for kind, suffix in [('pkg', '.pkg'), ('zip', '.zip'), ('source', '-source.tar.gz')]:
        original['files'][kind]['name'] = f'AIME-{version}{suffix}'
    template = root / 'template.json'
    template.write_text(json.dumps(original))
    sys.argv = ['rewrite', str(root), version, str(template)]
    exec(compile(body, str(script), 'exec'), {})
    result = json.loads((root / 'latest-beta.json').read_text())
    assert result['notes'] == 'preserve release notes'
    assert result['prerelease'] == ('-' in version)
    if '-' in version:
        assert not (root / 'latest.json').exists()
        # Seed the next iteration without relying on external artifacts.
        (root / 'latest.json').write_text(json.dumps(result))
    else:
        assert (root / 'latest.json').read_bytes() == (root / 'latest-beta.json').read_bytes()
PYTEST
echo 'PASS: beta/stable routing, signatures, checksums, missing key, stale cleanup, tampering and post-notarization rewrite'
