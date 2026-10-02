# Changelog

User-facing changes in each AIME release. The website's Changelog page is generated from this file. 中文：[CHANGELOG.md](CHANGELOG.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- One section per release: `## [version] - YYYY-MM-DD`, followed by a quoted status line (e.g. `> Developer preview · Developer ID signed · notarization pending`).
- Entries are grouped by type, using only these six, in this order: **Added**, **Changed**, **Fixed**, **Removed**, **Security**, **Known issues**. Omit empty types.
- One entry, one change a user can notice: where it happens and what changed. No internals or commit ids.
- Unreleased changes go under `## [Unreleased]` and move into the new version when it ships.
- Keep the versions, dates, status and types identical to CHANGELOG.md.

## [Unreleased]

## [0.1.2] - 2026-10-02

> Developer preview · Developer ID signed · notarization pending

### Fixed

- Settings › Sync & Backup › Sync Now: while the input method was running, a sync that actually failed still reported success. The input method now exports its own frequencies and failures are reported. A backup made after a failed sync now says it lacks the latest frequencies.
- Online word lists: AIME could redeploy every hour even when nothing was due (candidates cleared, "Deploying…" shown); it now redeploys only after downloading new content. Removing a subscription or changing its interval during an update is no longer overwritten.
- Restoring a backup: settings layers that were empty in the backup left the old settings in place; they are now replaced in full. A restore that fails midway rolls back to the state before it.
- After a failed deploy, the next deploy skipped the parts that failed and the candidate window's appearance could be wiped; the last working appearance is now kept and failed parts are rebuilt next time. Settings changed during a deploy are no longer missed.
- Typing statistics: switching windows quickly could drop counts, and cleared statistics could come back.
- Settings › Advanced: switching the file being edited during validation could write or roll back the wrong file; the target is now locked while validating.
- AI settings assistant: an invalid number from the model (such as NaN or infinity) crashed the Settings app; such suggestions are now rejected. Duplicate suggestions for one setting are merged, and conflicting ones are rejected together.
- AI term extraction: terms added under Xiaohe Shuangpin got full-pinyin codes and could not be typed; they now get Shuangpin codes.
- Quick menu: holding ⌥ while switching to another window could pop the menu up afterwards.
- The quick menu's symbol board hint no longer sits on the panel's bottom edge.

### Security

- Restoring rejects backups that contain symbolic links, would write outside the AIME folder, or are abnormally large.

### Known issues

- The installer is signed with ZOOL LLC's Developer ID; Apple notarization is still pending, so the first launch needs Control-click › Open in Finder.
- VoiceOver does not read candidates in the candidate window yet.

## [0.1.1] - 2026-10-02

> Developer preview · Developer ID signed · notarization pending

### Fixed

- Welcome guide, "Switch Chinese / English by app": after the scan the list could show only dividers with no apps or options; it now always appears in full.
- The scan in the same step is much faster: the scanning animation no longer reloads app icons on every frame, which made two or three hundred apps take over twenty seconds.

## [0.1.0] - 2026-10-01

> Developer preview · Developer ID signed · notarization pending

The first public developer preview.

### Added

- A macOS input method built on librime 1.17, with rime-ice by default, full pinyin and several shuangpin layouts; a native candidate window, horizontal or vertical, light and dark.
- **Quick menu**: hold ⌥ while typing; Space opens AI actions, digits open snippets, the symbol board, frequent words and settings.
- **AI actions**: translate, polish or run a custom action on selected text, what you just typed, or the candidate being chosen; results appear as candidates and Return replaces the text. Uses Apple's on-device model (depending on device and region) or your own OpenAI-compatible endpoint; Simplified/Traditional conversion runs locally.
- **Input layer (optional)**: text stays at the cursor as a draft before it is committed, so a whole passage can be processed before sending.
- Snippet categories, custom phrases and a default Chinese/English mode per app.
- 80+ visual settings, a theme gallery with live preview; one-click schema and vocabulary installs (pinned versions and SHA-256), with official online vocabulary updated daily or weekly.
- Read-only import from Squirrel; local backup and restore; word-frequency merge through the RIME sync folder.
- Typing statistics (optional, off by default, local only); a welcome guide.
- **Automatic updates**: checks the public release manifest daily, verifies the SHA-256 and developer signature after download, then hands over to the system installer; can be turned off.
- The `aime` command-line tool (deploy / bench / doctor / import-squirrel / package / get / set / sync / subscribe).
- The installer contains GPL-3.0 components and is distributed as a whole under GPL-3.0, with the corresponding source `AIME-0.1.0-source.tar.gz`.

### Known issues

- The installer is signed with ZOOL LLC's Developer ID; Apple notarization is still pending, so the first launch needs Control-click › Open in Finder.
- The `aime` command-line tool supports Apple silicon only.

[Unreleased]: https://github.com/zoolapp/aime/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/zoolapp/aime/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zoolapp/aime/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zoolapp/aime/releases/tag/v0.1.0
