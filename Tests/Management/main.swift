import CryptoKit
import Foundation

// Checks the Swift side of the admin protocol (Sources/Satellite/ManagementProtocol.swift): that it agrees with
// the JavaScript tool on the deterministic pieces (enrollment proof, token encoding), that seal/open round-trips,
// and that forged or stale envelopes are refused. With --emit-vector it prints a JSON vector for a cross-language
// check driven by the test script.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok  \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: Cross-language vector mode

if CommandLine.arguments.contains("--emit-vector") {
    // Fixed-ish keys so the Node side can load them: print both parties' private keys (base64url raw) and a sealed
    // message from admin to device. The script loads these in JS and opens the envelope.
    let admin = Management.Keys.create()
    let device = Management.Keys.create()
    struct Payload: Codable { var type = "policy"; var id = Management.newID(); var ts = Management.now(); var policy: ManagementPolicy }
    let payload = Payload(policy: ManagementPolicy(version: 5, issuedAt: 0, blockedIds: ["evil.ext"], pinned: ["quick-link": "1.2.0"], lockedSettings: ["mcp": "read"]))
    let sealed = try! Management.seal(admin, toSign: device.signHex, toKx: device.kxB64, payload)
    func jwk(_ priv: Data, _ pub: Data) -> [String: String] {
        ["d": priv.base64URLString, "x": pub.base64URLString]
    }
    let vector: [String: Any] = [
        "adminSignHex": admin.signHex, "adminKxB64": admin.kxB64,
        "device": [
            "sign": jwk(device.signing.rawRepresentation, device.signing.publicKey.rawRepresentation),
            "kx": jwk(device.agreement.rawRepresentation, device.agreement.publicKey.rawRepresentation),
        ],
        "sealed": sealed,
    ]
    let data = try! JSONSerialization.data(withJSONObject: vector)
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

extension Data { var base64URLString: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
} }

// MARK: Agreement with the JS reference values (tools/satellite-admin generated these)

let secret = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="
let adminSign = String(repeating: "a", count: 64)
let refKx = "CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk="
let proof = try! Management.enrollProof(secret: secret, deviceSign: adminSign, deviceKx: refKx)
check(proof == "PtitgfDVqMomZccVY89oD9vj5qy+SptGy8V8zK4B6QA=", "enroll proof matches the JavaScript tool")

let token = try! Management.parseToken("satadm1.eyJhIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImsiOiJDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrPSIsIm4iOiJUZWFtIiwicyI6IkJ3Y0hCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Y0hCd2M9IiwiZSI6MjAwMDAwMDAwMCwiaCI6IndzczovL2gifQ")
check(token.a == adminSign && token.n == "Team" && token.h == "wss://h" && token.s == secret, "token from the JavaScript tool parses")
check(Management.tokenValid(token), "a dated token from the tool is in date")

// A profile (expiry 0) parses and never expires — this is the mandatory, baked-in path.
let profile = try! Management.parseToken("satadm1.eyJhIjoiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYiIsImsiOiJBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNPSIsIm4iOiJUZWFtIiwicyI6IkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVU9IiwiZSI6MH0")
check(profile.e == 0 && Management.tokenValid(profile), "a profile (expiry 0) parses and never expires")

// MARK: Round trips within Swift

let admin = Management.Keys.create()
let device = Management.Keys.create()
struct Msg: Codable { var type = "policy"; var id = Management.newID(); var ts = Management.now(); var policy: ManagementPolicy }
let policy = ManagementPolicy(version: 3, issuedAt: Management.now(), blockedIds: ["x.y"], pinned: [:], lockedSettings: ["agent-text": "none"])
let sealed = try! Management.seal(admin, toSign: device.signHex, toKx: device.kxB64, Msg(policy: policy))

if let env = Management.peek(sealed, keys: device) {
    check(env.f == admin.signHex, "device sees an envelope addressed to it")
    struct Carrier: Decodable { var policy: ManagementPolicy }
    let opened = try? Management.open(Carrier.self, device, env, senderKx: admin.kxB64)
    check(opened?.1.policy == policy, "open round-trips the policy")
} else {
    check(false, "peek found the envelope")
}

let other = Management.Keys.create()
check(Management.peek(sealed, keys: other) == nil, "peek rejects an envelope for someone else")

// Forged signature: re-sign nothing; flip a ciphertext byte and keep the old signature.
if var env = Management.peek(sealed, keys: device) {
    env.c = String(env.c.dropLast()) + (env.c.hasSuffix("A") ? "B" : "A")
    struct Carrier: Decodable { var policy: ManagementPolicy }
    check((try? Management.open(Carrier.self, device, env, senderKx: admin.kxB64)) == nil, "open rejects a tampered envelope")
}

// Stale message.
struct Stale: Codable { var type = "policy"; var id = Management.newID(); var ts: Double }
let staleSealed = try! Management.seal(admin, toSign: device.signHex, toKx: device.kxB64, Stale(ts: Management.now() - (Management.maxSkew + 60) * 1000))
if let env = Management.peek(staleSealed, keys: device) {
    check((try? Management.open(Management.Message.self, device, env, senderKx: admin.kxB64)) == nil, "open rejects a stale message")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
