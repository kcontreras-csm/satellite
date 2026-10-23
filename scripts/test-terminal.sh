#!/bin/bash
# Checks terminal panes against your real login shell: launching, PATH, bracketed (safe) paste, refusing an unsafe
# paste, restarting an ended session, the assistants panel, and Send to Assistant into a terminal. Runs as a
# background process with an off-screen window and a throwaway SATELLITE_HOME; your clipboard isn't touched.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build >/dev/null   # builds SwiftTerm, whose objects the checks link against
BIN="$(swift build --show-bin-path)"
FILES=$(ls Sources/Satellite/*.swift | grep -v '/main.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -I "$BIN/Modules" \
  $FILES Tests/Terminal/main.swift "$BIN"/SwiftTerm.build/*.o -o "$WORK/checks"
SATELLITE_HOME="$WORK/home" "$WORK/checks"
