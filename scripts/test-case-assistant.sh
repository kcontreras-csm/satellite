#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library Sources/Satellite/CaseAssistant.swift Tests/CaseAssistant/FailureChecks.swift -o "$CHECK_DIR/failure-checks"
cp Tests/CaseAssistant/fake-app-server.py "$CHECK_DIR/fake-app-server.py"
chmod +x "$CHECK_DIR/fake-app-server.py"
"$CHECK_DIR/failure-checks" "$CHECK_DIR/fake-app-server.py"
