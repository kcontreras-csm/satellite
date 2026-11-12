import CryptoKit
import Foundation

/// The admin protocol between the `satellite-admin` tool and a managed Satellite, over Satella relay channels.
/// The tool has the same in JavaScript (tools/satellite-admin/protocol.cjs); keep the two the same.
///
/// A relay channel is an open wire: anyone can listen and send. So every message is an envelope signed with the
/// sender's Ed25519 key and encrypted (X25519 → HKDF-SHA256 → AES-256-GCM) to the one recipient. A device obeys
/// only envelopes signed by the admin it enrolled with, each message once, and policies whose version only rises.
enum Management {
    static let tag = "satadm-v1"
    static let tokenPrefix = "satadm1."
    static let maxSkew: TimeInterval = 15 * 60   // how old (or far ahead) a message may be, in seconds

    struct ProtocolError: LocalizedError { let errorDescription: String? ; init(_ m: String) { errorDescription = m } }

    // MARK: Keys

    /// A party's keys: Ed25519 to sign (also its Satella player key) and X25519 to agree on encryption keys.
    struct Keys {
        let signing: Curve25519.Signing.PrivateKey
        let agreement: Curve25519.KeyAgreement.PrivateKey

        /// Player key: the raw Ed25519 public key, hex.
        var signHex: String { signing.publicKey.rawRepresentation.hexString }
        /// Agreement public key, base64.
        var kxB64: String { agreement.publicKey.rawRepresentation.base64EncodedString() }

        static func create() -> Keys { Keys(signing: .init(), agreement: .init()) }

        func sign(_ data: Data) throws -> Data { try signing.signature(for: data) }

        /// Stored form: both private keys as base64, to keep in config/Keychain and load again.
        var stored: Stored { Stored(sign: signing.rawRepresentation.base64EncodedString(), kx: agreement.rawRepresentation.base64EncodedString()) }

        struct Stored: Codable { var sign: String; var kx: String }

        init(signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey) {
            self.signing = signing
            self.agreement = agreement
        }

        init(_ stored: Stored) throws {
            guard let s = Data(base64Encoded: stored.sign), let k = Data(base64Encoded: stored.kx) else {
                throw ProtocolError("Stored management keys are unreadable.")
            }
            signing = try .init(rawRepresentation: s)
            agreement = try .init(rawRepresentation: k)
        }
    }

    // MARK: Channels — named after key fingerprints, so they say nothing about who is behind them.

    static func fingerprint(_ signHex: String) -> String { String(signHex.prefix(16)) }
    static func adminInbox(_ adminSign: String) -> String { "satadm.\(fingerprint(adminSign))" }
    static func deviceInbox(admin adminSign: String, device deviceSign: String) -> String {
        "satadm.\(fingerprint(adminSign)).\(fingerprint(deviceSign))"
    }

    // MARK: Envelope

    struct Envelope: Codable {
        var v: Int
        var f: String        // sender signing key, hex
        var t: String        // recipient signing key, hex
        var k: String?       // sender agreement key, base64 — only on a first message (enrollment)
        var n: String        // AES-GCM nonce, base64
        var c: String        // ciphertext + tag, base64
        var g: String        // Ed25519 signature over the signed fields, base64
    }

    private static func signedBytes(_ e: Envelope) -> Data {
        [tag, e.f, e.t, e.k ?? "", e.n, e.c].joined(separator: "|").data(using: .utf8)!
    }

    /// The session key for a message from `from` to `to`, derived from our private agreement key and theirs.
    private static func sessionKey(_ keys: Keys, theirKx: String, from: String, to: String) throws -> SymmetricKey {
        guard let raw = Data(base64Encoded: theirKx) else { throw ProtocolError("Bad agreement key.") }
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let shared = try keys.agreement.sharedSecretFromKeyAgreement(with: theirs)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(tag.utf8),
            sharedInfo: "\(tag)|\(from)|\(to)".data(using: .utf8)!, outputByteCount: 32)
    }

    /// Seals `message` from `keys` to the party with signing key `toSign` and agreement key `toKx`.
    /// `includeKx` puts our agreement key in the envelope, for a first message (enrollment).
    static func seal<M: Encodable>(_ keys: Keys, toSign: String, toKx: String, _ message: M, includeKx: Bool = false) throws -> String {
        let key = try sessionKey(keys, theirKx: toKx, from: keys.signHex, to: toSign)
        let nonce = AES.GCM.Nonce()
        let aad = "\(keys.signHex)|\(toSign)".data(using: .utf8)!
        let plain = try JSONEncoder().encode(message)
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
        var env = Envelope(v: 1, f: keys.signHex, t: toSign, k: includeKx ? keys.kxB64 : nil,
                           n: Data(nonce).base64EncodedString(), c: (box.ciphertext + box.tag).base64EncodedString(), g: "")
        env.g = try keys.sign(signedBytes(env)).base64EncodedString()
        return String(data: try JSONEncoder().encode(env), encoding: .utf8)!
    }

    /// The envelope's outer fields, or nil when `text` isn't one addressed to `keys`. Checks nothing else.
    static func peek(_ text: String, keys: Keys) -> Envelope? {
        guard let data = text.data(using: .utf8), let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.v == 1, env.t == keys.signHex, env.f.count == 64, env.f.allSatisfy(\.isHexDigit) else { return nil }
        return env
    }

    /// Checks the signature and decrypts. `senderKx` is the sender's agreement key as we know it (or, for an
    /// enrollment, the one it sent in the envelope). Throws when anything doesn't add up.
    static func open<M: Decodable>(_ type: M.Type, _ keys: Keys, _ env: Envelope, senderKx: String?) throws -> (Message, M) {
        guard let kx = env.k ?? senderKx else { throw ProtocolError("No agreement key for \(fingerprint(env.f)).") }
        guard let signerRaw = Data(hex: env.f), let sig = Data(base64Encoded: env.g),
              let nonceData = Data(base64Encoded: env.n), let cipher = Data(base64Encoded: env.c), cipher.count > 16 else {
            throw ProtocolError("Malformed envelope.")
        }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: signerRaw)
        guard signer.isValidSignature(sig, for: signedBytes(env)) else { throw ProtocolError("Bad signature.") }
        let key = try sessionKey(keys, theirKx: kx, from: env.f, to: keys.signHex)
        let aad = "\(env.f)|\(keys.signHex)".data(using: .utf8)!
        let box = try AES.GCM.SealedBox(nonce: .init(data: nonceData),
                                        ciphertext: cipher.prefix(cipher.count - 16), tag: cipher.suffix(16))
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
        let envelope = try JSONDecoder().decode(Message.self, from: plain)
        guard abs(Date().timeIntervalSince1970 - envelope.ts / 1000) <= maxSkew else { throw ProtocolError("Message too old.") }
        let payload = try JSONDecoder().decode(M.self, from: plain)
        return (envelope, payload)
    }

    // MARK: Messages

    /// The fields every message carries. The rest are decoded per type.
    struct Message: Codable { var type: String; var id: String; var ts: Double }

    static func newID() -> String { Data((0..<12).map { _ in UInt8.random(in: 0...255) }).hexString }
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Enrollment token

    struct Token: Codable {
        var a: String       // admin signing key, hex
        var k: String       // admin agreement key, base64
        var n: String       // admin name
        var s: String       // one-time secret, base64
        var e: Double       // expiry, seconds since epoch
        var h: String?      // relay host override
    }

    static func parseToken(_ text: String) throws -> Token {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(tokenPrefix), let data = Data(base64URL: String(trimmed.dropFirst(tokenPrefix.count))) else {
            throw ProtocolError("That isn\u{2019}t a Satellite enrollment token.")
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    /// Whether a token is still usable now. A profile (expiry 0) never expires; a one-time token must be in date.
    static func tokenValid(_ token: Token) -> Bool { token.e == 0 || Date().timeIntervalSince1970 < token.e }

    /// The proof in an enrollment: HMAC-SHA256 keyed by the token secret over the device's keys, so only someone
    /// holding a token can enroll, and the proof can't be moved to other keys.
    static func enrollProof(secret: String, deviceSign: String, deviceKx: String) throws -> String {
        guard let key = Data(base64Encoded: secret) else { throw ProtocolError("Bad token secret.") }
        let mac = HMAC<SHA256>.authenticationCode(
            for: "\(tag)|enroll|\(deviceSign)|\(deviceKx)".data(using: .utf8)!, using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }
}

// MARK: - Small encodings

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(b); i = next
        }
        self = Data(bytes)
    }

    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
