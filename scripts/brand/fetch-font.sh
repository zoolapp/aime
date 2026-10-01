#!/usr/bin/env bash
set -euo pipefail
brand_root="$(cd "$(dirname "$0")/../.." && pwd)"
brand_cache="$brand_root/build/brand-fonts"
mkdir -p "$brand_cache"
brand_sha="a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
brand_font="$brand_cache/NotoSansSC.ttf"
if [[ ! -f "$brand_font" ]]; then
  curl --fail --location --max-time 60 --silent --show-error \
    'https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf' \
    -o "$brand_font"
fi
brand_actual="$(shasum -a 256 "$brand_font" | cut -d ' ' -f 1)"
[[ "$brand_actual" == "$brand_sha" ]] || { echo 'Noto Sans SC checksum differs; preserve current outlines and review the source.' >&2; exit 1; }
echo "Noto Sans SC checksum PASS: $brand_sha"
