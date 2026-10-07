#!/usr/bin/env bash
# Move Unreleased notes into a dated version section, retaining an empty Unreleased.
# By default CHANGELOG.md and CHANGELOG.en.md are promoted together (both are validated
# before either is written) and each new section gets its release status line;
# AIME_CHANGELOG_STATUS / AIME_CHANGELOG_STATUS_EN override the wording.
# AIME_CHANGELOG_FILE promotes that single file instead (offline fixture tests); it gets a
# status line only when AIME_CHANGELOG_STATUS is set. AIME_CHANGELOG_ROOT relocates the pair.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'usage: scripts/promote-changelog.sh <version> [YYYY-MM-DD]' >&2
  exit 1
fi
if [[ -n "${AIME_CHANGELOG_FILE:-}" ]]; then
  TARGETS=("$AIME_CHANGELOG_FILE" "${AIME_CHANGELOG_STATUS:-}")
else
  DIR="${AIME_CHANGELOG_ROOT:-$ROOT}"
  TARGETS=("$DIR/CHANGELOG.md" "${AIME_CHANGELOG_STATUS:-开发预览 · Developer ID 签名 · 公证处理中}"
           "$DIR/CHANGELOG.en.md" "${AIME_CHANGELOG_STATUS_EN:-Developer preview · Developer ID signed · notarization pending}")
fi
python3 - "$1" "${2:-$(date +%F)}" "${TARGETS[@]}" <<'PY'
import datetime
import os
import pathlib
import re
import sys
import tempfile

version, date = sys.argv[1], sys.argv[2]
targets = list(zip(sys.argv[3::2], sys.argv[4::2]))
def fail(message):
    raise SystemExit(f'promote-changelog: {message}')

if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?', version):
    fail('invalid version (expected X.Y.Z or X.Y.Z-beta.N)')
if '-' in version and any(part.isdigit() and len(part) > 1 and part.startswith('0') for part in version.split('-', 1)[1].split('.')):
    fail('numeric prerelease identifiers must not have leading zeros')
try:
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', date):
        fail('date must use YYYY-MM-DD')
    datetime.date.fromisoformat(date)
except ValueError:
    fail('invalid calendar date')

def promote(path, status):
    def fail(message):
        raise SystemExit(f'promote-changelog: {path.name}: {message}')
    raw = path.read_bytes().decode('utf-8')
    newline = '\r\n' if '\r\n' in raw else '\n'
    text = raw.replace('\r\n', '\n')
    if re.search(r'^## \[' + re.escape(version) + r'\](?:\s|$)', text, re.M):
        fail(f'version section [{version}] already exists')
    headers = list(re.finditer(r'^## \[Unreleased\][ \t]*$', text, re.M))
    if len(headers) != 1:
        fail('expected exactly one ## [Unreleased] section')
    header = headers[0]
    next_heading = re.search(r'^## ', text[header.end():], re.M)
    end = header.end() + next_heading.start() if next_heading else len(text)

    # A trailing reference table is not release content, even without an older section.
    reference_pattern = r'^\[([^\]]+)\]:[ \t]+(\S+)[ \t]*$'
    references = list(re.finditer(reference_pattern, text, re.M))
    footer_start = len(text)
    for reference in references:
        rest = re.sub(reference_pattern, '', text[reference.start():], flags=re.M)
        if not rest.strip():
            footer_start = reference.start()
            break
    end = min(end, footer_start)
    notes = text[header.end():end].strip('\n')
    meaningful = re.sub(r'<!--.*?-->', '', notes, flags=re.S)
    meaningful = re.sub(r'^\s*#{1,6}\s+.*$', '', meaningful, flags=re.M)
    if not meaningful.strip():
        fail('Unreleased is empty')

    if status and not notes.lstrip('\n').startswith('> '):
        notes = f'> {status}\n\n' + notes
    result = text[:header.end()] + f'\n\n## [{version}] - {date}\n\n' + notes.rstrip() + '\n\n' + text[end:]
    if footer_start < len(text):
        refs = {m.group(1): m.group(2) for m in references if m.start() >= footer_start}
        if version in refs:
            fail(f'link reference [{version}] already exists')
        unreleased = refs.get('Unreleased', '')
        compare = re.fullmatch(r'(.+)/compare/(.+)\.\.\.(.+)', unreleased)
        previous = re.search(r'^## \[([^\]]+)\]', text[end:footer_start], re.M)
        old_version = previous.group(1) if previous else None
        if compare:
            base, old_tag, head = compare.groups()
            prefix = 'v' if old_tag.startswith('v') else ''
        else:
            base, prefix, head = 'https://github.com/zoolapp/aime', 'v', 'HEAD'
            for url in refs.values():
                known = re.fullmatch(r'(.+)/(?:compare|releases/tag)/(.+)', url)
                if known:
                    base = known.group(1)
                    prefix = 'v' if known.group(2).startswith('v') else ''
                    break
            old_tag = prefix + old_version if old_version else None
        new_tag = prefix + version
        new_unreleased = f'[Unreleased]: {base}/compare/{new_tag}...{head}'
        new_release = (f'[{version}]: {base}/compare/{old_tag}...{new_tag}' if old_tag
                       else f'[{version}]: {base}/releases/tag/{new_tag}')
        if 'Unreleased' in refs:
            result = re.sub(r'^\[Unreleased\]:[^\n]*$', lambda _: new_unreleased + '\n' + new_release, result, flags=re.M)
        else:
            footer = text[footer_start:]
            result = result[:-len(footer)] + new_unreleased + '\n' + new_release + '\n' + footer

    return path, result, newline

results = [promote(pathlib.Path(path), status) for path, status in targets]

# All validation precedes the only mutation. Preserve line endings and file mode.
for path, result, newline in results:
    mode = path.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.changelog-', delete=False) as output:
        temporary = pathlib.Path(output.name)
        try:
            output.write(result.replace('\n', newline).encode('utf-8'))
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
print(f'Promoted Unreleased to [{version}] - {date}')
PY
