#!/usr/bin/env bash
# Render the AIME launch film to dist/video/ (4K master + 1080p). Offline after the one-time installs below.
set -euo pipefail
cd "$(dirname "$0")/../.."
bash scripts/brand/fetch-font.sh >/dev/null           # pinned Noto Sans SC → build/brand-fonts/
if [ -z "${AIME_VIDEO_NODE_MODULES:-}" ] && [ ! -d build/video-tools/node_modules/playwright-core ]; then
  mkdir -p build/video-tools
  [ -f build/video-tools/package.json ] || echo '{"private":true}' > build/video-tools/package.json
  npm install --prefix build/video-tools --no-audit --no-fund playwright-core@1.56.1
fi
# A headless shell is required; install the one matching playwright-core only when none is cached.
if [ -z "${AIME_CHROME:-}" ] && ! ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-* >/dev/null 2>&1; then
  node build/video-tools/node_modules/playwright-core/cli.js install chromium-headless-shell
fi
node scripts/video/render-launch.mjs "$@"
if [ "$#" -eq 0 ]; then bash scripts/video/add-audio.sh; fi   # full render: add the score
