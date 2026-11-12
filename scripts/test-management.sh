#!/bin/bash
# Checks the device-management protocol: the Swift side on its own, that it agrees with the JavaScript admin tool,
# and that an envelope sealed in Swift opens in JavaScript (and the admin tool's own tests pass).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== admin tool (JavaScript) =="
node tools/satellite-admin/test/protocol.test.mjs

echo "== Satellite side (Swift) =="
swift build >/dev/null   # builds SwiftTerm, whose objects the checks link against
BIN="$(swift build --show-bin-path)"
FILES=$(ls Sources/Satellite/*.swift | grep -v '/main.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -I "$BIN/Modules" \
  $FILES Tests/Management/main.swift "$BIN"/SwiftTerm.build/*.o -o "$WORK/checks"
SATELLITE_HOME="$WORK/home" "$WORK/checks"

echo "== cross-language: Swift seals, JavaScript opens =="
SATELLITE_HOME="$WORK/home" "$WORK/checks" --emit-vector > "$WORK/vector.json"
VECTOR="$WORK/vector.json" node --input-type=module -e '
import fs from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(process.cwd() + "/");
const P = require("./tools/satellite-admin/protocol.cjs");
const { webcrypto: crypto } = await import("node:crypto");
const v = JSON.parse(fs.readFileSync(process.env.VECTOR, "utf8"));
// Rebuild the device keys from the raw private/public halves Swift printed.
const jwk = (crv, k, ops) => ({ kty: "OKP", crv, d: k.d, x: k.x });
const stored = {
  sign: jwk("Ed25519", v.device.sign),
  kx: jwk("X25519", v.device.kx),
};
const keys = await P.loadKeys(stored);
const env = P.peek(v.sealed, keys);
if (!env) throw new Error("JS could not peek the Swift envelope");
const message = await P.open(keys, env, v.adminKxB64);
if (message.type !== "policy" || message.policy.version !== 5 || message.policy.blockedIds[0] !== "evil.ext") {
  throw new Error("JS opened the wrong contents: " + JSON.stringify(message));
}
console.log("  ok  JavaScript opened the Swift-sealed policy (v" + message.policy.version + ")");
'

echo "== native relay client (Swift) over the real relay =="
RELAY="$(SATELLITE_HOME="$WORK/home" "$WORK/checks" --relay-selftest || true)"
case "$RELAY" in
  RELAY-OK) echo "  ok  SatellaConnection connected, subscribed, sent and received" ;;
  RELAY-TIMEOUT) echo "  skip  no relay reachable (offline); native client not exercised" ;;
  *) echo "  FAIL  native relay client: $RELAY"; exit 1 ;;
esac

echo "== web dashboard (admin tool) =="
(
  cd tools/satellite-admin
  export SATELLITE_ADMIN_HOME="$WORK/admin"
  PORT=8791
  node satellite-admin.mjs init --name "Suite" >/dev/null
  node satellite-admin.mjs serve --port "$PORT" > "$WORK/serve.log" 2>&1 &
  SERVE=$!
  trap 'kill $SERVE 2>/dev/null' EXIT
  for _ in $(seq 1 20); do grep -q "Dashboard:" "$WORK/serve.log" && break; sleep 0.3; done
  KEY="$(grep -o 'k=[A-Za-z0-9_-]*' "$WORK/serve.log" | head -1 | cut -d= -f2)"
  [ -n "$KEY" ] || { echo "  FAIL dashboard didn't start"; cat "$WORK/serve.log"; exit 1; }
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/api/block" -d '{"ids":["x"]}')
  [ "$code" = "401" ] && echo "  ok  API rejects requests with no key" || { echo "  FAIL no-key POST returned $code"; exit 1; }
  curl -s -X POST "http://127.0.0.1:$PORT/api/block" -H "authorization: Bearer $KEY" -H 'content-type: application/json' -d '{"ids":["evil.ext"]}' >/dev/null
  blocked=$(curl -s "http://127.0.0.1:$PORT/api/state?k=$KEY" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(d.policy.blockedIds.join(","))')
  [ "$blocked" = "evil.ext" ] && echo "  ok  block via the dashboard takes effect" || { echo "  FAIL blocked=$blocked"; exit 1; }
  curl -s "http://127.0.0.1:$PORT/" | head -1 | grep -q '<!doctype html>' && echo "  ok  the dashboard page is served" || { echo "  FAIL no html"; exit 1; }
)

echo "All management checks passed."
