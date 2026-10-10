# Changelog

User-facing changes in each AIME release. The website's Changelog page is generated from this file. 中文：[CHANGELOG.md](CHANGELOG.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- One section per release: `## [version] - YYYY-MM-DD`, followed by a quoted status line (e.g. `> Developer preview · Developer ID signed · notarization pending`).
- Entries are grouped by type, using only these six, in this order: **Added**, **Changed**, **Fixed**, **Removed**, **Security**, **Known issues**. Omit empty types.
- One entry, one change a user can notice: where it happens and what changed. No internals or commit ids.
- Unreleased changes go under `## [Unreleased]` and move into the new version when it ships.
- Keep the versions, dates, status and types identical to CHANGELOG.md.

## [Unreleased]

## [0.1.8] - 2026-10-10

> Stable release · Developer ID signed · notarized by Apple

### Added

- Settings › Typing › Punctuation: choose Chinese or English punctuation as the default while typing Chinese. Switching with ⌃⇧3 now applies to every app instead of only the current one.
- Settings › Shortcuts › hold-to-open key: Option, Control and Command can each be limited to the left or right key only (e.g. right ⌥), leaving the other side for normal use; pick “either side” to keep the old behavior.

### Fixed

- ⌃⇧3 (Chinese/English punctuation) and ⌃⇧4 (Simplified/Traditional) did nothing while typing. Both work now, and other Control+Shift combinations such as Control+Shift+/ match the key names used in settings.
- After Caps Lock switched to English, pressing it again did not switch back to Chinese; only Shift did. Caps Lock now toggles both ways, like Squirrel.
- The 以词定字 (pick a character from a word) shortcuts in Settings › Shortcuts could not be cleared and kept [ ] busy, so [ ] paging did nothing. The shortcuts now have a clear button; turning on [ ] paging clears 以词定字 keys still on [ or ], and setting 以词定字 to [ or ] turns [ ] paging off.

## [0.1.7] - 2026-10-09

> Stable release · Developer ID signed · notarized by Apple

### Added

- Settings › Appearance › Fonts: besides the five presets, candidate, label and comment sizes can be set in 1 pt steps with the ± control next to them. Candidates go up to 40 pt, labels and comments up to 32 pt, and changing other settings no longer resets the size.

### Fixed

- With AIME selected, pressing ⌘, in any app opened AIME's settings instead of that app's own. The input menu no longer takes ⌘,.
- With double pinyin schemes such as Xiaohe, the zh/z, an/ang, en/eng and other fuzzy pinyin switches in Settings › Fuzzy pinyin & spelling had no effect. They now work; switches turned on earlier are corrected on upgrade, no need to set them again.
- In some apps the vertical candidate list showed the AIME menu button on the input code row, above the candidates. In vertical layout it now always sits below the list.
- Right after a first install, while macOS had not yet added AIME to the input source list, Settings and onboarding still said it was enabled. They now say to log out or restart the Mac once, and the installer's last page says so too.

## [0.1.6] - 2026-10-07

> Stable release · Developer ID signed · notarized by Apple

### Changed

- The menu bar input source icon is now 「艾」 in a rounded square, the same style as macOS's own input sources and Squirrel, so it lines up with them in width and spacing.

### Fixed

- Settings › Vocabulary › sentence language model: downloading "Wanxiang · Simplified sentence model" failed with HTTP 403 or 404. Upstream replaced the model file in place, and GitHub rate-limits anonymous downloads, so the old address stopped working. AIME now fetches the upstream release of 2026-10-06 (about 398 MB) from its own download server and verifies it by SHA-256.
- With Wanxiang Pinyin, once Backspace had emptied the composition, further Backspace presses could not delete committed text until another key was pressed. Now only a held Backspace stops at the empty composition to protect committed text; single presses delete as usual.

## [0.1.5] - 2026-10-07

> Stable release · Developer ID signed · notarized by Apple

### Fixed

- When installing with the package or Homebrew while another copy of AIME.app existed elsewhere (for example an old copy in Downloads), the installer updated that copy instead of installing to /Library/Input Methods, so AIME was missing from System Settings. It now always installs to /Library/Input Methods.
- If the input method does not end up where expected after installation, the installer now reports a failure instead of success.

## [0.1.4] - 2026-10-07

> Stable release · Developer ID signed · notarized by Apple

### Added

- Settings › Overview has a new "Export Diagnostics…" button. It packs the version, installation state, update state and filtered logs into one ZIP to attach to a bug report; it never includes typed text, word frequencies, frequent phrases, statistics, configuration contents or keys. `aime diagnostics --output <file>.zip` exports the same from the command line; see docs/troubleshooting.md.
- Settings › Overview has a new "Receive beta versions" option. When on, update checks also offer beta versions; when off, only stable releases. A stable release always counts as newer than a beta with the same number.
- The input layer handles Command+V plain-text appends, preserving newlines and emoji. An addition that exceeds draft capacity is rejected as a whole instead of committing the draft early.

### Changed

- Quick-menu hold triggers and schema-switcher shortcuts are grouped in Keyboard Shortcuts; Appearance keeps the candidate-window menu button's visibility setting.
- About uses a narrower content column and aligned version details, Chinese build dates and a GitHub icon for the repository link.
- Vocabulary settings uses Added and Available lists so subscribed official feeds appear once.
- The schema switcher caption setting explains where its prompt appears in composition or the candidate panel.

### Fixed

- Skipping a version in Settings no longer overwrites the update check the input method just recorded, and the input method no longer shows a notification for the skipped version.
- Imported themes support the legacy highlighted-background field and numeric colors with leading zeroes.
- Hotkey recording saves after all keys and modifiers are released and stops on pane or window changes to avoid duplicate entries.
- The three default schema-switcher bindings keep their names on one line in the minimum settings window.

### Known issues

- Real-host draft paste routing, physical modifier-hold recording and the caret issue after cancelling snippets still need testing after installation.
- The emoji board, vocabulary settings and About page from 0.1.3 still need native acceptance in real input hosts.

## [0.1.3] - 2026-10-05

> Local development build · ad-hoc signed · native acceptance pending

### Added

- Optional Wanxiang offline sentence model download and settings, preserving imported configuration; download and activation are off by default.
- Quick-menu key 4 opens an offline emoji board with 1906 Unicode 16.0 sequences in nine categories, using the symbol board's keyboard and continuous-insertion controls.
- An About page and native About menu show the version, build time, licenses and repository.

### Changed

- Quick-menu settings moves to key 0, reserving 1–9 for content entries; 0 still selects the tenth category inside the symbol board.
- Vocabulary settings distinguishes the base dictionary from supplemental feeds; manual and automatic refresh share catalog checks. New subscriptions are capped at 32, with up to 32 checks per batch.

### Fixed

- Consumed quick-menu or input-layer keys no longer accidentally switch language modes, and an old input context cannot overwrite the current mode. Stale modifier-hold timers no longer open the menu after leaving a field.
- Equal-count vocabulary replacements and code or weight changes trigger a rebuild; identical content and 304 responses skip redeployment.
- Continuous menu insertion clears old composition so Escape does not restore earlier pinyin; directly uninstalling an offline model clears its configuration references.
- Dictionary capacity metadata is generated with public resource permissions so it remains readable after system installation.

### Known issues

- The emoji board, vocabulary settings and About page still need native acceptance; the caret issue after cancelling snippets with Escape has not been reproduced in a real IMK host.

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

[Unreleased]: https://github.com/zoolapp/aime/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/zoolapp/aime/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/zoolapp/aime/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/zoolapp/aime/compare/v0.1.2...v0.1.4
[0.1.2]: https://github.com/zoolapp/aime/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zoolapp/aime/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zoolapp/aime/releases/tag/v0.1.0
