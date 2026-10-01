#!/usr/bin/env bash
# Builds the release artefacts for one version into dist/release/ (or $AIME_RELEASE_DIR):
#   AIME-<version>.pkg    installer (scripts/package.sh)
#   AIME-<version>.zip    AIME.app (with the CLI and AIME Settings.app inside)
#   SHA256SUMS.txt        checksums of the two files above
#   RELEASE_NOTES.md      CHANGELOG section + signing status + checksums (not an asset)
#
# Usage: bash scripts/release.sh <version>      e.g. 0.2.0 or 0.2.0-beta.1 (a leading "v" is ok)
#
# Signing follows the existing scripts: ad-hoc unless AIME_SIGN_IDENTITY (Developer ID
# Application) is set; the pkg is signed when AIME_INSTALLER_IDENTITY (Developer ID
# Installer) is set. Notarization runs when all of AIME_NOTARY_KEY_PATH (.p8),
# AIME_NOTARY_KEY_ID and AIME_NOTARY_ISSUER_ID are set (App Store Connect API key).
# Used by .github/workflows/release.yml; safe to run locally (writes only build/ and dist/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
BASE_VERSION="${VERSION%%-*}"
OUT="${AIME_RELEASE_DIR:-$ROOT/dist/release}"

# The bundle and CLI versions come from the sources; the tag must agree with them.
APP_VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
CLI_VERSION="$(awk -F'"' '/^[[:space:]]*version: "/ {print $2; exit}' Packages/AIMEKit/Sources/aime/AIME.swift)"
if [[ "$APP_VERSION" != "$BASE_VERSION" || "$CLI_VERSION" != "$BASE_VERSION" ]]; then
  echo "version mismatch: tag $VERSION, project.yml MARKETING_VERSION $APP_VERSION, CLI $CLI_VERSION" >&2
  echo "update both (see docs/release-checklist.md) before tagging" >&2
  exit 1
fi

IDENTITY="${AIME_SIGN_IDENTITY:--}"
NOTARIZE=0
if [[ -n "${AIME_NOTARY_KEY_PATH:-}" && -n "${AIME_NOTARY_KEY_ID:-}" && -n "${AIME_NOTARY_ISSUER_ID:-}" ]]; then
  NOTARIZE=1
  [[ "$IDENTITY" != "-" && -n "${AIME_INSTALLER_IDENTITY:-}" ]] \
    || { echo "notarization needs AIME_SIGN_IDENTITY and AIME_INSTALLER_IDENTITY" >&2; exit 1; }
fi
if [[ "$NOTARIZE" == 1 ]]; then STATUS=notarized
elif [[ "$IDENTITY" != "-" ]]; then STATUS=signed
else STATUS=preview
fi
echo "==> AIME $VERSION ($STATUS)"

notarize() {  # <file>: submit, wait (bounded) and require "Accepted"
  local file="$1" result id
  result="$(xcrun notarytool submit "$file" --key "$AIME_NOTARY_KEY_PATH" --key-id "$AIME_NOTARY_KEY_ID" \
    --issuer "$AIME_NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json)" || true
  id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)" != Accepted ]]; then
    echo "notarization of $(basename "$file") failed: $result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --key "$AIME_NOTARY_KEY_PATH" \
      --key-id "$AIME_NOTARY_KEY_ID" --issuer "$AIME_NOTARY_ISSUER_ID" >&2 || true
    return 1
  fi
  echo "==> notarized $(basename "$file") (submission $id)"
}

AIME_REQUIRE_TIMESTAMP=$([[ "$IDENTITY" == "-" ]] && echo 0 || echo 1) bash scripts/build-app.sh
APP="$ROOT/build/Release/AIME.app"

rm -rf "$OUT" && mkdir -p "$OUT"
PKG="$OUT/AIME-$VERSION.pkg"
ZIP="$OUT/AIME-$VERSION.zip"

if [[ "$NOTARIZE" == 1 ]]; then
  # Notarize and staple the app first so both the zip and the pkg carry the ticket.
  ditto -c -k --keepParent "$APP" "$OUT/notarize-app.zip"
  notarize "$OUT/notarize-app.zip"
  rm -f "$OUT/notarize-app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

SKIP_BUILD=1 bash scripts/package.sh
mv "dist/AIME-$APP_VERSION.pkg" "$PKG"
if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$PKG"
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$PKG")" "$(basename "$ZIP")" > SHA256SUMS.txt)

# Release notes: the CHANGELOG section for this version, else a template.
NOTES="$OUT/RELEASE_NOTES.md"
SECTION="$(awk -v v="$VERSION" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## / { exit }
  on && /^\[[^]]+\]: / { next }
  on { print }' CHANGELOG.md 2>/dev/null || true)"
{
  if [[ -n "${SECTION//[[:space:]]/}" ]]; then
    printf '%s\n' "$SECTION"
  else
    printf '## AIME %s\n\n更新内容见 [CHANGELOG.md](CHANGELOG.md)。\n' "$VERSION"
  fi
  echo
  echo "## 签名状态"
  echo
  case "$STATUS" in
    notarized)
      echo "已使用 Developer ID 签名（Hardened Runtime + 可信时间戳），并通过 Apple 公证、已装订票据。" ;;
    signed)
      echo "已使用 Developer ID 签名，**未经 Apple 公证**。" ;;
    preview)
      cat <<'MD'
**预览版：未使用 Developer ID 签名（仅 ad-hoc 签名），未经 Apple 公证。** 仅供了解风险的测试者使用。

安装前先核对 SHA-256（见下文）。

- **安装包 `.pkg`**：双击若被拦截，在 Finder 中右键 › 打开；新版 macOS 需到「系统设置 › 隐私与安全性」点「仍要打开」。
  也可以只对这个文件去掉隔离属性：`xattr -d com.apple.quarantine AIME-*.pkg`。
- **压缩包 `.zip`**：解压后把 `AIME.app` 放进 `~/Library/Input Methods/`，仅在信任该产物时执行
  `xattr -dr com.apple.quarantine "$HOME/Library/Input Methods/AIME.app"`。不要关闭系统全局 Gatekeeper。
MD
      ;;
  esac
  echo
  echo "安装后在「系统设置 › 键盘 › 输入法」中添加「艾么输入法」；首次安装可能需要注销并重新登录一次。"
  echo
  echo "最低系统：macOS 26。输入法与设置应用为 universal（Apple Silicon + Intel）；内置的 \`aime\` 命令行工具随构建机架构（当前为 Apple Silicon）。"
  echo
  echo "## SHA-256"
  echo
  echo '```'
  cat "$OUT/SHA256SUMS.txt"
  echo '```'
  echo
  # shellcheck disable=SC2016  # literal Markdown backticks
  echo '校验：把文件和 `SHA256SUMS.txt` 放在同一目录，执行 `shasum -a 256 -c SHA256SUMS.txt`。'
} > "$NOTES"

echo "$STATUS" > "$OUT/SIGNING_STATUS"
echo "==> release artefacts in $OUT"
ls -l "$OUT"
