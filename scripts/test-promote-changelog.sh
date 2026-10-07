#!/usr/bin/env bash
# All mutations are confined to temporary CHANGELOG fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/promote-changelog.sh"
WORK="$(mktemp -d -t aime-changelog-test)"
trap 'rm -rf "$WORK"' EXIT
export AIME_CHANGELOG_FILE="$WORK/CHANGELOG with spaces.md"
expect_failure() {
  cp "$AIME_CHANGELOG_FILE" "$WORK/before.md"
  if bash "$SCRIPT" "$@" > "$WORK/error.log" 2>&1; then
    echo "FAIL: expected rejection for $*" >&2; exit 1
  fi
  cmp "$AIME_CHANGELOG_FILE" "$WORK/before.md"
}
cat > "$AIME_CHANGELOG_FILE" <<'MD'
# Changelog

## [Unreleased]

### Added

- New feature with `literal $value`.

## [0.1.0] - 2026-10-01

- Existing release.

[Unreleased]: https://example.invalid/project/compare/v0.1.0...HEAD
[0.1.0]: https://example.invalid/project/releases/tag/v0.1.0
MD
chmod 640 "$AIME_CHANGELOG_FILE"
bash "$SCRIPT" 0.2.0-beta.1 2026-10-02
python3 - "$AIME_CHANGELOG_FILE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
assert '## [Unreleased]\n\n## [0.2.0-beta.1] - 2026-10-02\n\n### Added' in s
assert s.count('- New feature with `literal $value`.') == 1
assert '- Existing release.' in s
assert '[Unreleased]: https://example.invalid/project/compare/v0.2.0-beta.1...HEAD' in s
assert '[0.2.0-beta.1]: https://example.invalid/project/compare/v0.1.0...v0.2.0-beta.1' in s
assert p.stat().st_mode & 0o777 == 0o640
PY
expect_failure 0.2.0-beta.1 2026-10-03
expect_failure 0.3.0 2026-10-03  # Empty Unreleased, despite an existing reference table.
expect_failure 0.3.0 2026-02-30
expect_failure 'not-a-version' 2026-10-03
expect_failure 0.3.0-beta.01 2026-10-03
# No footer or previous release; omitted date uses the local date.
printf '# Changelog\n\n## [Unreleased]\n\n- First release.\n' > "$AIME_CHANGELOG_FILE"
bash "$SCRIPT" 1.0.0
python3 - "$AIME_CHANGELOG_FILE" <<'PY'
import datetime, pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
assert f'## [1.0.0] - {datetime.date.today().isoformat()}' in s
assert s.endswith('- First release.\n\n')
assert '[1.0.0]:' not in s
PY
# A reference table alone is not content, nor are placeholder headings/comments.
printf '## [Unreleased]\n\n[Unreleased]: https://example.invalid/p/compare/v1.0.0...HEAD\n' > "$AIME_CHANGELOG_FILE"
expect_failure 1.1.0
printf '## [Unreleased]\n\n### Added\n<!-- add notes here -->\n' > "$AIME_CHANGELOG_FILE"
expect_failure 1.1.0
printf '# No unreleased section\n' > "$AIME_CHANGELOG_FILE"
expect_failure 1.1.0
# Trailing references without Unreleased; infer repository and unprefixed tags.
cat > "$AIME_CHANGELOG_FILE" <<'MD'
## [Unreleased]

- Next.

## [1.0.0] - 2026-10-01

- Old.

[1.0.0]: https://example.invalid/p/releases/tag/1.0.0
MD
bash "$SCRIPT" 1.1.0 2026-10-03
python3 - "$AIME_CHANGELOG_FILE" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
assert '[Unreleased]: https://example.invalid/p/compare/1.1.0...HEAD' in s
assert '[1.1.0]: https://example.invalid/p/compare/1.0.0...1.1.0' in s
PY
# CRLF input and a footer immediately after the first-ever Unreleased section.
printf '## [Unreleased]\r\n\r\n- First.\r\n\r\n[issue]: https://example.invalid/issues/1\r\n' > "$AIME_CHANGELOG_FILE"
bash "$SCRIPT" 0.1.0 2026-10-01
python3 - "$AIME_CHANGELOG_FILE" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_bytes()
assert b'\r\n' in s and b'\n' not in s.replace(b'\r\n', b'')
assert b'[0.1.0]: https://github.com/zoolapp/aime/releases/tag/v0.1.0' in s
assert s.count(b'[issue]:') == 1
PY
# A status line goes right under the new heading when one is given.
printf '## [Unreleased]\n\n### Fixed\n\n- A fix.\n' > "$AIME_CHANGELOG_FILE"
AIME_CHANGELOG_STATUS='Preview · notarization pending' bash "$SCRIPT" 0.4.0 2026-10-04
python3 - "$AIME_CHANGELOG_FILE" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
assert '## [0.4.0] - 2026-10-04\n\n> Preview · notarization pending\n\n### Fixed\n\n- A fix.' in s, s
PY
# Default mode promotes CHANGELOG.md and CHANGELOG.en.md together, each with its status.
unset AIME_CHANGELOG_FILE
export AIME_CHANGELOG_ROOT="$WORK/pair"
mkdir -p "$AIME_CHANGELOG_ROOT"
printf '## [Unreleased]\n\n### 新增\n\n- 新功能。\n' > "$AIME_CHANGELOG_ROOT/CHANGELOG.md"
printf '## [Unreleased]\n\n### Added\n\n- New feature.\n' > "$AIME_CHANGELOG_ROOT/CHANGELOG.en.md"
bash "$SCRIPT" 0.5.0 2026-10-05
python3 - "$AIME_CHANGELOG_ROOT" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
zh, en = (d / 'CHANGELOG.md').read_text(), (d / 'CHANGELOG.en.md').read_text()
assert '## [0.5.0] - 2026-10-05\n\n> 开发预览 · Developer ID 签名 · 公证处理中\n\n### 新增' in zh, zh
assert '## [0.5.0] - 2026-10-05\n\n> Developer preview · Developer ID signed · notarization pending\n\n### Added' in en, en
PY
# If either file cannot be promoted, neither is written.
printf '## [Unreleased]\n\n### 新增\n\n- 又一个。\n' > "$AIME_CHANGELOG_ROOT/CHANGELOG.md"
printf '## [Unreleased]\n\n' > "$AIME_CHANGELOG_ROOT/CHANGELOG.en.md"
cp "$AIME_CHANGELOG_ROOT/CHANGELOG.md" "$WORK/zh-before.md"
if bash "$SCRIPT" 0.6.0 2026-10-06 > "$WORK/error.log" 2>&1; then echo 'FAIL: expected pair rejection' >&2; exit 1; fi
grep -q 'CHANGELOG.en.md: Unreleased is empty' "$WORK/error.log"
cmp "$AIME_CHANGELOG_ROOT/CHANGELOG.md" "$WORK/zh-before.md"
echo 'PASS: promotion, beta, dates, duplicate/empty rejection, references, CRLF, mode, status lines, zh/en pair and atomic failures'
