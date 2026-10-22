#!/bin/bash
# Checks installing extensions from a GitHub address: address parsing, git refs, commit pinning, lookup and install,
# against a local stand-in for github.com and raw.githubusercontent.com. Builds the checks optimized as well as debug,
# because the installer has broken only in optimized builds before.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

S=Sources/Satellite
SOURCES=("$S/GitHubInstall.swift" "$S/GitHubSource.swift" "$S/Store.swift" "$S/Manifest.swift" "$S/SemVer.swift"
         "$S/ExtensionInstaller.swift" "$S/Models.swift" "$S/ExtensionSettings.swift" Tests/GitHubInstall/GitHubInstallChecks.swift)

for mode in debug optimized; do
  flags=(-Onone); [ "$mode" = optimized ] && flags=(-O)
  swiftc -parse-as-library "${flags[@]}" "${SOURCES[@]}" -o "$WORK/checks-$mode"

  rm -f "$WORK/port"
  python3 Tests/GitHubInstall/fake-github.py "$WORK/port" & SERVER_PID=$!
  for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
  BASE="http://127.0.0.1:$(cat "$WORK/port")"

  echo "== $mode build =="
  rm -rf "$WORK/home"
  SATELLITE_HOME="$WORK/home" SATELLITE_GITHUB_WEB="$BASE/web" SATELLITE_GITHUB_RAW="$BASE/raw" FAKE_GITHUB="$BASE" \
    "$WORK/checks-$mode"
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
done
