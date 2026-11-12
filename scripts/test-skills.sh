#!/bin/bash
# Checks the Claude Code skills store: list, install (verified, with origin), update and remove, using the local
# source and throwaway folders.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build >/dev/null   # builds SwiftTerm, whose objects the checks link against
BIN="$(swift build --show-bin-path)"
FILES=$(ls Sources/Satellite/*.swift | grep -v '/main.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -I "$BIN/Modules" \
  $FILES Tests/Skills/main.swift "$BIN"/SwiftTerm.build/*.o -o "$WORK/checks"

export SATELLITE_HOME="$WORK/home"
export SATELLITE_SKILLS_STORE_DIR="$WORK/repo"
export SATELLITE_SKILLS_DIR="$WORK/installed"
mkdir -p "$SATELLITE_SKILLS_STORE_DIR" "$SATELLITE_SKILLS_DIR"
"$WORK/checks"
