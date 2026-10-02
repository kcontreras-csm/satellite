import CommonCrypto
import CryptoKit
import Foundation

enum UserVerification: String {
    case required, preferred, discouraged
}

// MARK: - Authenticator info

struct AuthenticatorInfo {
    var versions: [String] = []
    var aaguid = Data()
    var options: [String: Bool] = [:]
    var pinProtocols: [Int] = [1]
    var maxCredentialCountInList: Int?
    var maxCredentialIdLength: Int?

    init() {}

    init(_ cbor: CBOR) {
        versions = cbor[1]?.arrayValue?.compactMap(\.textValue) ?? []
        aaguid = cbor[3]?.dataValue ?? Data()
        for (key, value) in cbor[4]?.mapValue ?? [] {
            if let name = key.textValue, let flag = value.boolValue { options[name] = flag }
        }
        pinProtocols = cbor[6]?.arrayValue?.compactMap(\.intValue) ?? [1]
        maxCredentialCountInList = cbor[7]?.intValue
        maxCredentialIdLength = cbor[8]?.intValue
    }

    var hasPIN: Bool { options["clientPin"] == true }
    var hasBuiltInUV: Bool { options["uv"] == true }
    var supportsResidentKeys: Bool { options["rk"] == true }
    var supportsPinUvAuthToken: Bool { options["pinUvAuthToken"] == true }
}

// MARK: - PIN protocols

struct PinSecret {
    let aesKey: Data
    let hmacKey: Data
}

/// CTAP2 PIN/UV auth protocols 1 and 2.
enum PinProtocol: Int {
    case v1 = 1
    case v2 = 2

    static func choose(from supported: [Int]) -> PinProtocol {
        supported.contains(1) ? .v1 : (supported.contains(2) ? .v2 : .v1)
    }

    func deriveSecret(from z: Data) -> PinSecret {
        switch self {
        case .v1:
            let key = Data(SHA256.hash(data: z))
            return PinSecret(aesKey: key, hmacKey: key)
        case .v2:
            func derive(_ info: String) -> Data {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: z), salt: Data(repeating: 0, count: 32),
                    info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
            }
            return PinSecret(aesKey: derive("CTAP2 AES key"), hmacKey: derive("CTAP2 HMAC key"))
        }
    }

    func encrypt(_ data: Data, with secret: PinSecret) throws -> Data {
        switch self {
        case .v1:
            return try Self.aesCBC(encrypt: true, key: secret.aesKey, iv: Data(count: 16), data: data)
        case .v2:
            let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            return iv + (try Self.aesCBC(encrypt: true, key: secret.aesKey, iv: iv, data: data))
        }
    }

    func decrypt(_ data: Data, with secret: PinSecret) throws -> Data {
        switch self {
        case .v1:
            return try Self.aesCBC(encrypt: false, key: secret.aesKey, iv: Data(count: 16), data: data)
        case .v2:
            guard data.count > 16 else { throw SecurityKeyError.protocolError("short PIN reply") }
            return try Self.aesCBC(encrypt: false, key: secret.aesKey, iv: data.prefix(16), data: data.dropFirst(16))
        }
    }

    /// The pinUvAuthParam: HMAC-SHA-256 of `message` under `key`, cut to 16 bytes for protocol 1.
    func authenticate(key: Data, message: Data) -> Data {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        return self == .v1 ? Data(mac.prefix(16)) : mac
    }

    private static func aesCBC(encrypt: Bool, key: Data, iv: Data, data: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SecurityKeyError.protocolError("PIN encryption failed") }
        return output.prefix(moved)
    }
}

// MARK: - FIDO2 client

struct MakeCredentialRequest {
    var clientDataHash: Data
    var rpId: String
    var rpName: String
    var userId: Data
    var userName: String
    var userDisplayName: String
    var algorithms: [Int]
    var exclude: [Data]
    var residentKey: Bool
    var userVerification: UserVerification
}

struct MadeCredential {
    var format: String
    var authenticatorData: Data
    var attestationStatement: CBOR
}

struct Assertion {
    var credentialId: Data
    var authenticatorData: Data
    var signature: Data
    var userId: Data?
    var userName: String?
    var userDisplayName: String?
}

/// Talks CTAP2 to one key: getInfo, makeCredential, getAssertion and the PIN handshake.
@MainActor
struct CTAP2Client {
    let transport: CTAPTransport
    let info: AuthenticatorInfo
    /// Asks the user for the key's PIN. `retries` is how many tries are left (if known); `wrong` is true after a bad PIN.
    let askPIN: (_ retries: Int?, _ wrong: Bool) async -> String?

    static func connect(_ transport: CTAPTransport, askPIN: @escaping (Int?, Bool) async -> String?) async throws -> CTAP2Client {
        let response = try await transport.cbor(Data([0x04]))
        return CTAP2Client(transport: transport, info: AuthenticatorInfo(try CBOR.decode(response)), askPIN: askPIN)
    }

    // MARK: makeCredential

    func makeCredential(_ r: MakeCredentialRequest) async throws -> MadeCredential {
        var uvOption = false
        var token: (Data, PinProtocol)?

        switch r.userVerification {
        case .required:
            if info.hasBuiltInUV { uvOption = true }
            else if info.hasPIN { token = try await pinToken(permissions: 0x01, rpId: r.rpId) }
            else { throw CTAPError(code: CTAPError.pinNotSet) }
        case .preferred:
            if info.hasPIN { token = try await pinToken(permissions: 0x01, rpId: r.rpId) }
        case .discouraged:
            break
        }

        func build(_ token: (Data, PinProtocol)?) -> Data {
            var options: [(CBOR, CBOR)] = []
            if r.residentKey { options.append((.text("rk"), .bool(true))) }
            if uvOption { options.append((.text("uv"), .bool(true))) }

            var map: [(CBOR, CBOR)] = [
                (.int(1), .bytes(r.clientDataHash)),
                (.int(2), .map([(.text("id"), .text(r.rpId)), (.text("name"), .text(r.rpName))])),
                (.int(3), .map([(.text("id"), .bytes(r.userId)), (.text("name"), .text(r.userName)),
                                (.text("displayName"), .text(r.userDisplayName))])),
                (.int(4), .array(r.algorithms.map { .map([(.text("alg"), .int($0)), (.text("type"), .text("public-key"))]) })),
            ]
            if !r.exclude.isEmpty {
                map.append((.int(5), .array(r.exclude.map { .map([(.text("type"), .text("public-key")), (.text("id"), .bytes($0))]) })))
            }
            if !options.isEmpty { map.append((.int(7), .map(options))) }
            if let (secret, proto) = token {
                map.append((.int(8), .bytes(proto.authenticate(key: secret, message: r.clientDataHash))))
                map.append((.int(9), .int(proto.rawValue)))
            }
            return Data([0x01]) + CBOR.map(map).encoded()
        }

        let reply: Data
        do {
            reply = try await transport.cbor(build(token))
        } catch let error as CTAPError where error.code == CTAPError.pinRequired && token == nil && info.hasPIN {
            reply = try await transport.cbor(build(try await pinToken(permissions: 0x01, rpId: r.rpId)))
        }

        let response = try CBOR.decode(reply)
        guard let format = response[1]?.textValue, let authData = response[2]?.dataValue else {
            throw SecurityKeyError.protocolError("incomplete credential")
        }
        return MadeCredential(format: format, authenticatorData: authData, attestationStatement: response[3] ?? .map([]))
    }

    // MARK: getAssertion

    func getAssertions(rpId: String, clientDataHash: Data, allow: [Data], userVerification: UserVerification) async throws -> [Assertion] {
        var token: (Data, PinProtocol)?
        var uvOption = false
        if userVerification == .required {
            if info.hasBuiltInUV { uvOption = true }
            else if info.hasPIN { token = try await pinToken(permissions: 0x02, rpId: rpId) }
            else { throw CTAPError(code: CTAPError.pinNotSet) }
        }

        func build(_ batch: [Data], _ token: (Data, PinProtocol)?) -> Data {
            var map: [(CBOR, CBOR)] = [(.int(1), .text(rpId)), (.int(2), .bytes(clientDataHash))]
            if !batch.isEmpty {
                map.append((.int(3), .array(batch.map { .map([(.text("type"), .text("public-key")), (.text("id"), .bytes($0))]) })))
            }
            if uvOption { map.append((.int(5), .map([(.text("uv"), .bool(true))]))) }
            if let (secret, proto) = token {
                map.append((.int(6), .bytes(proto.authenticate(key: secret, message: clientDataHash))))
                map.append((.int(7), .int(proto.rawValue)))
            }
            return Data([0x02]) + CBOR.map(map).encoded()
        }

        // Keys only accept so many credential ids per request, so try the allowed ones in batches.
        let usable = allow.filter { $0.count <= (info.maxCredentialIdLength ?? Int.max) }
        let batchSize = max(1, info.maxCredentialCountInList ?? 1)
        let batches: [[Data]] = usable.isEmpty ? [[]] : stride(from: 0, to: usable.count, by: batchSize).map { Array(usable[$0..<min($0 + batchSize, usable.count)]) }
        if !allow.isEmpty && usable.isEmpty { throw CTAPError(code: CTAPError.noCredentials) }

        var lastError: Error = CTAPError(code: CTAPError.noCredentials)
        for batch in batches {
            do {
                var currentToken = token
                var reply: Data
                do {
                    reply = try await transport.cbor(build(batch, currentToken))
                } catch let error as CTAPError where error.code == CTAPError.pinRequired && currentToken == nil && info.hasPIN {
                    currentToken = try await pinToken(permissions: 0x02, rpId: rpId)
                    reply = try await transport.cbor(build(batch, currentToken))
                }

                let first = try CBOR.decode(reply)
                var results = [try assertion(from: first, fallback: batch.count == 1 ? batch[0] : nil)]
                let total = first[5]?.intValue ?? 1
                if total > 1 && allow.isEmpty {
                    for _ in 1..<min(total, 16) {
                        let next = try CBOR.decode(try await transport.cbor(Data([0x08])))
                        results.append(try assertion(from: next, fallback: nil))
                    }
                }
                return results
            } catch let error as CTAPError where error.code == CTAPError.noCredentials {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func assertion(from response: CBOR, fallback: Data?) throws -> Assertion {
        guard let authData = response[2]?.dataValue, let signature = response[3]?.dataValue,
              let credentialId = response[1]?["id"]?.dataValue ?? fallback else {
            throw SecurityKeyError.protocolError("incomplete assertion")
        }
        let user = response[4]
        return Assertion(
            credentialId: credentialId, authenticatorData: authData, signature: signature,
            userId: user?["id"]?.dataValue, userName: user?["name"]?.textValue, userDisplayName: user?["displayName"]?.textValue)
    }

    // MARK: PIN

    /// Runs the PIN handshake, asking for the PIN (again, if it is wrong) until it works or the user gives up.
    private func pinToken(permissions: Int, rpId: String) async throws -> (Data, PinProtocol) {
        let proto = PinProtocol.choose(from: info.pinProtocols)
        var wrong = false
        while true {
            let retries = try? await pinRetries(proto)
            guard let pin = await askPIN(retries, wrong) else { throw CancellationError() }
            do {
                return (try await requestToken(pin: pin, proto: proto, permissions: permissions, rpId: rpId), proto)
            } catch let error as CTAPError where error.code == CTAPError.pinInvalid {
                wrong = true
            }
        }
    }

    private func pinRetries(_ proto: PinProtocol) async throws -> Int? {
        let request = Data([0x06]) + CBOR.map([(.int(1), .int(proto.rawValue)), (.int(2), .int(1))]).encoded()
        return try CBOR.decode(try await transport.cbor(request))[3]?.intValue
    }

    private func requestToken(pin: String, proto: PinProtocol, permissions: Int, rpId: String) async throws -> Data {
        // 1. Agree on a shared secret with the key (ECDH on P-256).
        let agreement = Data([0x06]) + CBOR.map([(.int(1), .int(proto.rawValue)), (.int(2), .int(2))]).encoded()
        let keyReply = try CBOR.decode(try await transport.cbor(agreement))
        guard let x = keyReply[1]?[-2]?.dataValue, let y = keyReply[1]?[-3]?.dataValue, x.count == 32, y.count == 32 else {
            throw SecurityKeyError.protocolError("bad key agreement reply")
        }
        let authenticatorKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y)
        let platformKey = P256.KeyAgreement.PrivateKey()
        let z = try platformKey.sharedSecretFromKeyAgreement(with: authenticatorKey).withUnsafeBytes { Data($0) }
        let secret = proto.deriveSecret(from: z)
        let point = platformKey.publicKey.x963Representation
        let platformCOSE = CBOR.map([
            (.int(1), .int(2)), (.int(3), .int(-25)), (.int(-1), .int(1)),
            (.int(-2), .bytes(Data(point[1..<33]))), (.int(-3), .bytes(Data(point[33..<65]))),
        ])

        // 2. Send the PIN hash encrypted under that secret, get the PIN token back.
        let pinHash = Data(SHA256.hash(data: Data(pin.precomposedStringWithCanonicalMapping.utf8)).prefix(16))
        var params: [(CBOR, CBOR)] = [
            (.int(1), .int(proto.rawValue)), (.int(3), platformCOSE), (.int(6), .bytes(try proto.encrypt(pinHash, with: secret))),
        ]
        if info.supportsPinUvAuthToken {
            params += [(.int(2), .int(0x09)), (.int(9), .int(permissions)), (.int(10), .text(rpId))]
        } else {
            params.append((.int(2), .int(0x05)))
        }
        let reply = try CBOR.decode(try await transport.cbor(Data([0x06]) + CBOR.map(params).encoded()))
        guard let encrypted = reply[2]?.dataValue else { throw SecurityKeyError.protocolError("no PIN token") }
        return try proto.decrypt(encrypted, with: secret)
    }
}

// MARK: - U2F (CTAP1) for older keys

@MainActor
struct U2FClient {
    let transport: CTAPTransport

    struct Registration {
        var publicKey: Data
        var keyHandle: Data
        var certificate: Data
        var signature: Data
    }

    struct Authentication {
        var keyHandle: Data
        var flags: UInt8
        var counter: Data
        var signature: Data
    }

    private static let needsTouch: UInt16 = 0x6985
    private static let wrongData: UInt16 = 0x6A80

    func register(appParam: Data, challengeParam: Data, exclude: [Data]) async throws -> Registration {
        for handle in exclude {
            let (status, _) = try await send(ins: 0x02, p1: 0x07, data: challengeParam + appParam + Data([UInt8(handle.count)]) + handle)
            if status == Self.needsTouch { throw CTAPError(code: CTAPError.credentialExcluded) }
        }
        let (_, body) = try await pollForTouch { try await send(ins: 0x01, p1: 0x00, data: challengeParam + appParam) }
        let bytes = [UInt8](body)
        guard bytes.count > 67, bytes[0] == 0x05 else { throw SecurityKeyError.protocolError("bad U2F registration") }
        let publicKey = Data(bytes[1..<66])
        let handleLength = Int(bytes[66])
        guard bytes.count > 67 + handleLength else { throw SecurityKeyError.protocolError("bad U2F registration") }
        let handle = Data(bytes[67..<67 + handleLength])
        let rest = Array(bytes[(67 + handleLength)...])
        let certificateLength = try Self.derLength(rest)
        guard rest.count >= certificateLength else { throw SecurityKeyError.protocolError("bad U2F certificate") }
        return Registration(publicKey: publicKey, keyHandle: handle, certificate: Data(rest[0..<certificateLength]), signature: Data(rest[certificateLength...]))
    }

    func authenticate(appParam: Data, challengeParam: Data, allow: [Data]) async throws -> Authentication {
        for handle in allow {
            let payload = challengeParam + appParam + Data([UInt8(handle.count)]) + handle
            let (probe, _) = try await send(ins: 0x02, p1: 0x07, data: payload)
            guard probe == Self.needsTouch else { continue }  // 0x6A80: this key doesn't know the handle
            let (_, body) = try await pollForTouch { try await send(ins: 0x02, p1: 0x03, data: payload) }
            let bytes = [UInt8](body)
            guard bytes.count > 5 else { throw SecurityKeyError.protocolError("bad U2F assertion") }
            return Authentication(keyHandle: handle, flags: bytes[0], counter: Data(bytes[1..<5]), signature: Data(bytes[5...]))
        }
        throw CTAPError(code: CTAPError.noCredentials)
    }

    /// Repeats the request while the key is waiting for a touch.
    private func pollForTouch(_ request: () async throws -> (UInt16, Data)) async throws -> (UInt16, Data) {
        while true {
            let (status, body) = try await request()
            if status == 0x9000 { return (status, body) }
            guard status == Self.needsTouch else { throw CTAPError(code: status == Self.wrongData ? CTAPError.noCredentials : CTAPError.operationDenied) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func send(ins: UInt8, p1: UInt8, data: Data) async throws -> (UInt16, Data) {
        var apdu = Data([0x00, ins, p1, 0x00, 0x00, UInt8(data.count >> 8), UInt8(data.count & 0xFF)])
        apdu.append(data)
        apdu.append(contentsOf: [0x00, 0x00])
        let reply = [UInt8](try await transport.msg(apdu))
        guard reply.count >= 2 else { throw SecurityKeyError.protocolError("short U2F reply") }
        let status = UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
        return (status, Data(reply.dropLast(2)))
    }

    /// Length of the DER structure at the start of `bytes` (the attestation certificate).
    private static func derLength(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count > 2, bytes[0] == 0x30 else { throw SecurityKeyError.protocolError("bad certificate") }
        if bytes[1] < 0x80 { return 2 + Int(bytes[1]) }
        let count = Int(bytes[1] & 0x7F)
        guard count > 0, count <= 3, bytes.count >= 2 + count else { throw SecurityKeyError.protocolError("bad certificate") }
        return 2 + count + bytes[2..<2 + count].reduce(0) { ($0 << 8) | Int($1) }
    }
}
