# Security policy

## Supported versions

AIME is an alpha-stage MVP with an implemented macOS input method, settings app, and CLI. Reports about the current development code and its dependencies are welcome; there is no published backport policy or guaranteed response time.

## Reporting a vulnerability

Do not publish exploit details, credentials, personal configuration, typed text, or user-frequency databases in issues, PRs, or logs.

Use GitHub's **Report a vulnerability** action in the repository's [Security tab](https://github.com/zoolapp/aime/security) if private vulnerability reporting is enabled. This document does not assert that it is enabled. Otherwise, contact maintainer **Luo Lei (@foru17)** through a private contact method listed on [the maintainer's profile](https://github.com/foru17). If no private channel is available, open a minimal issue requesting one, with no vulnerability details or personal data, and wait for a private channel before sharing the report.

Privately include the affected commit/version, macOS and toolchain versions, impact, a minimal reproduction with synthetic data, and any proposed mitigation. Maintainers will triage the report and coordinate remediation and disclosure with the reporter; no fixed response SLA is promised.

## Implemented security and privacy measures

The following measures are implemented in the current MVP. They do not constitute a completed security audit; see [privacy notes](docs/privacy.md) and [architecture](docs/architecture.md) for details.

- **Local input processing, no telemetry.** Keystrokes stay inside the input-method process, which does not make network requests. librime logs default to WARNING and do not record typed text. AIME includes no analytics, crash-reporting, or telemetry SDKs.
- **AI boundary.** `AIMEAI` depends on `AIMECore`, not `RimeKit`; active input, composition/preedit text, and user-frequency data are not passed to it. AI runs only on user request and defaults to Apple Foundation Models on-device. Remote OpenAI-compatible providers require explicit configuration; requests contain the assistant request, public settings catalog and current values, or text pasted for vocabulary extraction. There is no silent remote fallback.
- **Credentials and configuration review.** Remote provider keys are stored in `~/Library/Application Support/AIME/credentials.json` (directory 0700, file 0600), outside the Rime user directory so they are never synced or exported; a key saved in the login Keychain by an earlier build is moved there and the Keychain item removed. The assistant validates proposed settings and previews changes before the user applies them. Keep keys out of YAML, repository files, crash reports, screenshots, and logs.
- **Read-only migration and separate data.** Squirrel import reads `~/Library/Rime` without modifying it and skips live `*.userdb` databases. It can copy `sync/*/*.userdb.txt` snapshots into AIME's sync directory for local frequency merging. AIME uses `~/Library/AIME/Rime`; advanced YAML edits are validated through a temporary `aime deploy --dry-run` workspace and rolled back on failure.
- **Pinned downloads and SHA-256 verification.** The librime fetch script verifies its lock-file digests; dictionary downloads use registry-pinned versions and SHA-256 hashes. The package manager rejects checksum mismatches, including local payloads. A digest verifies integrity against the recorded value, not trust in the upstream author; review source and license changes before updates.
- **Package path protection and ownership.** Package installation filters out symlinks, unsafe relative paths, AIME control files, user databases, and user configuration patches. It checks destination parents against the AIME workspace and refuses to overwrite symlinks. Files overwritten outside a previous installation's ownership are backed up. Upgrade/uninstall uses recorded file hashes and preserves modified files and files shared with other packages. Dictionaries can include executable Lua; these checks do not make third-party scripts trusted.
- **Development signing.** `scripts/install-dev.sh` uses ad-hoc signing by default and verifies the signed bundle. Do not sign with a revoked certificate: macOS can classify the app as malware and move it to Trash. Override `AIME_SIGN_IDENTITY` only with a valid identity.

The [CI workflow](.github/workflows/ci.yml) runs package tests, dictionary validation, and the latency gate. Tests cover checksum rejection, package file filtering/ownership, read-only import, and AI proposal validation. The separate privacy acceptance check documented in `docs/privacy.md` must find no matches:

```bash
! grep -rlE 'composing|preedit|userdb' Packages/AIMEKit/Sources/AIMEAI
```

Tests and diagnostics must use synthetic input and redact secrets. Never request a user's entire RIME directory as a bug-report attachment.

## Scope

Relevant reports include unsafe configuration deployment, unintended writes to Squirrel data, malicious dictionary installation, secret leakage, AI boundary violations, input-process vulnerabilities, and dependency supply-chain failures. Ordinary reproducible bugs belong in the bug form after removing sensitive data.
