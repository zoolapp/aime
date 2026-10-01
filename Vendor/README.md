# Vendor

Downloaded, pinned third-party binaries. Nothing here except `*.lock` and this file is committed.

- `librime.lock` — librime release, commit and sha256 of the prebuilt archives. `scripts/fetch-librime.sh`
  downloads them into `.cache/`, verifies the hashes and assembles `librime/` plus
  `Packages/AIMEKit/Frameworks/CRime.xcframework`.
- Dictionary archives (rime-ice) are cached in `.cache/` by `scripts/fetch-dicts.sh`, pinned in `dicts/registry.json`.
