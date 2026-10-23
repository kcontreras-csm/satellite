#!/bin/bash
# Checks copying links: File > Copy Link (and with title), and the right-click menus of tabs and of apps in the rail.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build >/dev/null   # builds SwiftTerm, whose objects the checks link against
BIN="$(swift build --show-bin-path)"
FILES=$(ls Sources/Satellite/*.swift | grep -v '/main.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -I "$BIN/Modules" \
  $FILES Tests/Links/main.swift "$BIN"/SwiftTerm.build/*.o -o "$WORK/checks"
SATELLITE_HOME="$WORK/home" "$WORK/checks"
