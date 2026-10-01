# Changelog

All notable changes to AIME will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioned releases are intended to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- ZOOL LLC development signing configuration (team `PX694P4CGY`); certificate-backed builds use secure timestamps.
- **Online vocabularies**: subscribe to any GitHub / raw URL (RIME `dict.yaml`, `word<TAB>code<TAB>weight` tables or
  plain word lists); checked hourly, each feed at most every 12 h with ETag; shows entry count, new words and the
  remote update time; works in full pinyin and 小鹤双拼. CLI `aime subscribe`.
- **高频词 statistics** (opt-in, local only): day / week / month dashboard, pin a word as a custom phrase, block, clear.
- **AI polish**: select text anywhere and press ⌃⌥P for 润色 / 正式 / 简洁 rewrites in the candidate window.
- Settings without free-text input: key recorder, font picker, switch lists and presets.
- Candidate window appear and resize motion (Core Animation, respects Reduce Motion).

### Fixed

- The bundled `aime_tech_2026` vocabulary was never loaded (`enable_user_dict: false` makes librime skip the table),
  and tagged rows lost their weights.

## [0.1.0] - 2026-09-29

First MVP.

### Added

- **Input method** (`AIME.app`): InputMethodKit frontend for librime 1.17 with lua / octagram / predict plugins,
  AppKit + Core Text candidate panel (linear / stacked, light / dark schemes, translucency, mouse selection),
  per-app options (default English, no inline, Vim mode), status bubbles, input menu actions.
- **Settings** (`AIME Settings.app`): overview, schema list, catalog-driven panes (input habits, switching, fuzzy
  pinyin, shortcuts), appearance with live preview and scheme gallery, app options, dictionary packages, custom
  phrases, sync directory, AI assistant, advanced YAML editing with dry-run validation and rollback.
- **CLI** `aime`: deploy (with `--dry-run`), bench (`--assert-p99-ms`), doctor, import-squirrel, package
  list/install/uninstall, get/set, sync, register.
- **Config layering**: defaults / imported / generated layers composed into a literal patch; collection maps merge
  per item; workspace lock and deploy request ids.
- **Squirrel import**: read-only import of `~/Library/Rime` including custom patches, Lua, color schemes and
  frequency snapshots.
- **Dictionaries**: registry of pinned, sha256-verified packages (rime-ice, Wanxiang, rime-frost, rime-essay) with
  transactional install, backups and shared-file ownership; bundled `aime_tech_2026` vocabulary (473 entries).
- **RIME configuration reference** (`docs/rime-config-reference.md`) and a catalog of 79 settings.
- **AI assistant** (optional): natural-language configuration proposals validated against the catalog, vocabulary
  extraction with locally computed pinyin; Apple on-device model or OpenAI-compatible endpoint with Keychain key.
- Architecture docs, ADR-0001–0004, privacy notes, CI (build, test, benchmark gate, unsigned artifact).

### Performance

- rime-ice with Lua extensions: p50 0.34 ms / p99 0.61 ms per keystroke (`aime bench`, Apple Silicon).

[Unreleased]: https://github.com/zoolapp/aime/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/zoolapp/aime/releases/tag/v0.1.0
