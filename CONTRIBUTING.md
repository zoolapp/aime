# Contributing to AIME

**English** | [中文](CONTRIBUTING.zh.md)

Focused bug reports, documentation fixes, dictionary proposals, and code contributions are welcome. Follow the [Code of Conduct](CODE_OF_CONDUCT.md); report vulnerabilities using [SECURITY.md](SECURITY.md).

## Development environment

Use macOS 26+, Xcode 26+ with command-line tools selected, and XcodeGen (`brew install xcodegen`). The Swift package requires Swift tools 6.2+ and uses Swift 6 strict concurrency. Install SwiftLint for local lint checks. Scripts also use Git, Bash, curl, Python 3, and Ruby. Record the exact tool versions used; CI selects the latest stable Xcode on `macos-26`.

`Packages/AIMEKit` contains `RimeKit`, `AIMECore`, `AIMEPanel`, `AIMEAI`, and the `aime` CLI. `project.yml` defines the two app targets: `AIME.app` (InputMethodKit/AppKit) and `AIME Settings.app` (SwiftUI). See [architecture](docs/architecture.md) and the [decision records](docs/decisions/) for module boundaries.

## Build and install

Fork the repository and create a focused branch from the current default branch. Run from the repository root:

```bash
bash scripts/fetch-librime.sh
mkdir -p Packages/AIMEKit/.build
bash scripts/fetch-dicts.sh
swift build --package-path Packages/AIMEKit
bash scripts/stage-plugins.sh
xcodegen generate
xcodebuild -project AIME.xcodeproj -scheme AIME -configuration Debug -derivedDataPath build/DerivedData build
```

The fetch scripts verify pinned SHA-256 digests and assemble librime and `build/SharedSupport`. Create `.build` before the first dictionary fetch because it also invokes plugin staging. Run `stage-plugins.sh` after each new SwiftPM build configuration so Lua, octagram, and predict load beside that configuration's librime copy. The `AIME` scheme builds both apps; its post-build script embeds librime plugins and SharedSupport.

To build and install for the current user:

```bash
bash scripts/install-dev.sh
```

The installer builds Release apps and CLI, installs to `~/Library/Input Methods/AIME.app`, and registers the input source. Add AIME in System Settings → Keyboard → Input Sources; log out and back in if it does not appear. Development installation uses **ad-hoc signing by default**. Do not use a revoked certificate: macOS can treat the signed app as malware and move it to Trash. Set `AIME_SIGN_IDENTITY` only to a valid signing identity when overriding the default.

Do not commit downloaded binaries, generated projects, build output, or local input-method data. `swift scripts/gen-icons.swift` regenerates the app and menu-bar icons when changing those assets.

## Implementation boundaries

- Keep librime in the input-method process and CLI; the settings app does not link it. Keep networking and AI outside the keystroke path. CI enforces key-event p99 ≤ 5 ms with `aime bench`; report measurements for your workload rather than treating the threshold as a universal guarantee.
- Enable Swift strict concurrency. Keep technical identifiers and commit messages in English; update both language versions of paired documents.
- Preserve `~/Library/Rime` during import. Write AIME data only to its independent directory; test `__patch` layer precedence and dry-run validation with temporary fixtures.
- AI is optional, manually invoked, and defaults to Apple's on-device model. AI only receives the text of an action the user explicitly runs (input-layer draft, selection, or text just committed); never pinyin strings, candidate lists, the user-frequency database, or statistics; no telemetry. Preview configuration diffs before applying. Provider keys live in the owner-only file `~/Library/Application Support/AIME/credentials.json` (tests use `AIME_CREDENTIALS_FILE`), never repository files or test logs. See [privacy notes](docs/privacy.md).
- Keep dictionary downloads separate from application source, with pinned provenance, SHA-256 checks, and upstream license notices.

## Licensing: no copied GPL source

**Do not copy, translate, port, or adapt GPL source code into AIME's MIT source tree, including Squirrel code.** AIME is not a Squirrel fork. This applies to AI-generated patches derived from such code as well. Use independently written implementations and compatible, attributed dependencies.

`scripts/fetch-dicts.sh` downloads GPL-3.0 rime-ice data at build time. It ships as a separate work in the app's `Contents/SharedSupport/`, with its `LICENSE`; it is not committed to this repository. This data distribution does not permit importing GPL implementation code into AIME's MIT source. Preserve upstream license and distribution obligations. For every new dependency or dataset, record its upstream URL, version/commit, license, and notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). If provenance or permission is unclear, resolve it before inclusion; never assume a public repository means MIT.

Original code contributions are under MIT. Word lists are maintained in [zoolapp/aime-dicts](https://github.com/zoolapp/aime-dicts) (CC BY 4.0); contribute entries there with attribution and provenance.

## Tests and verification

After the build setup above, run checks relevant to your change. The package uses Swift Testing, including real librime deployment tests:

```bash
swift test --package-path Packages/AIMEKit
swift scripts/build-dicts.swift --check
swiftlint lint --config .swiftlint.yml
```

Use Swift Testing for new behavior and regression cases. Test deployment/patch precedence, malformed YAML, read-only import (source contents and timestamps unchanged), download checksum failures, upgrade/uninstall boundaries, and AI consent/data isolation when touching those areas. Tests must use disposable directories and synthetic text, not personal RIME files or live cloud credentials. Bound retries and batch work.

For input-path changes, build the Release CLI, stage its plugins, and benchmark in a temporary user directory:

```bash
swift build --package-path Packages/AIMEKit -c release --product aime
bash scripts/stage-plugins.sh
AIME_BENCH_DIR="$(mktemp -d -t aime-bench)"
"$(swift build --package-path Packages/AIMEKit -c release --show-bin-path)/aime" bench \
  --user-dir "$AIME_BENCH_DIR" --shared-dir build/SharedSupport \
  --schema rime_ice --keys nihaoshijie --iterations 2000 --assert-p99-ms 5
```

Attach hardware, macOS/toolchain, dictionary/schema, workload, sample count, p99 latency, and resident memory measurements. The benchmark exits with failure if p99 exceeds 5 ms.

For UI changes, after the Debug app build above, run in a logged-in graphical session with screen-capture permission:

```bash
bash scripts/ui-shots.sh
```

Screenshots are saved to `.ui-acceptance/<date>/` in light and dark modes. Also check normal and narrow window widths, keyboard navigation, clipping, and candidate placement. If using the installer’s Release build, run `APP="$PWD/build/DerivedData/Build/Products/Release/AIME Settings.app" bash scripts/ui-shots.sh`.

[CI](.github/workflows/ci.yml) fetches dependencies, stages plugins, runs package tests and the Release benchmark, validates dictionaries, and builds and archives an unsigned app. SwiftLint and screenshots are local checks. The privacy acceptance check from [docs/privacy.md](docs/privacy.md) must return no matches (it is a separate local check, not a step in the current workflow):

```bash
! grep -rlE 'composing|preedit|userdb' Packages/AIMEKit/Sources/AIMEAI
```

Documentation-only changes must keep English/Chinese meaning aligned and check local links. Parse repository YAML with:

```bash
ruby -ryaml -e '(Dir[".github/ISSUE_TEMPLATE/*.yml"] + [".swiftlint.yml", "project.yml", ".github/workflows/ci.yml"]).each { |f| YAML.parse_file(f) }'
```

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): summary`; scope is optional. Examples: `docs: clarify setup status`, `fix(rime): preserve imported overrides`, `feat(settings): preview candidate colors`. Use `!` and a `BREAKING CHANGE:` footer for incompatible changes.

1. Search existing issues; discuss substantial behavior or dependency changes before implementation.
2. Keep one concern per branch/PR, with small commits and no unrelated refactoring.
3. Run relevant checks, inspect the diff for secrets, personal data, generated artifacts, and license provenance, then commit. For AI-assisted commits made by Codex, add `Co-Authored-By: Codex <noreply@openai.com>` as a trailer.
4. Fill in the PR template: problem, resulting behavior, linked issue, exact verification results, and limitations. Update both READMEs/contribution guides when applicable; add shipped changes under `Unreleased` in the changelog and track open work in GitHub Issues.
5. Request review and address feedback. Do not claim CI passed without a run, or merge/publish on behalf of maintainers without authorization.

For troubleshooting and diagnostic exports, see the [troubleshooting guide (Chinese)](docs/troubleshooting.md).
