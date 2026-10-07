#!/usr/bin/env bash
# Produce a dated Info.plist input before Xcode processes and signs it.
set -euo pipefail
PLIST="${DERIVED_FILE_DIR:?}/AIMEInfo.plist"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$DERIVED_FILE_DIR"
cp "${AIME_INFO_TEMPLATE:?}" "$PLIST"
/usr/bin/plutil -replace AIMEBuildDate -string "$STAMP" "$PLIST"
