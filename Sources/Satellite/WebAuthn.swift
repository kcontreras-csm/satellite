import CryptoKit
import Foundation

// MARK: - Errors and encoding

/// An error a web page sees as a DOMException (or TypeError).
struct WebAuthnFailure: Error, LocalizedError {
    let name: String
    let message: String
    var errorDescription: String? { message }

    init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    static func notAllowed(_ message: String) -> WebAuthnFailure { WebAuthnFailure(name: "NotAllowedError", message: message) }
    static func typeError(_ message: String) -> WebAuthnFailure { WebAuthnFailure(name: "TypeError", message: message) }

    /// Maps lower-level errors onto what the WebAuthn specification tells a browser to report.
    init(_ error: Error) {
        if let failure = error as? WebAuthnFailure {
            self = failure
        } else if error is CancellationError {
            self = .notAllowed("The operation was cancelled.")
        } else if let ctap = error as? CTAPError {
            switch ctap.code {
            case CTAPError.credentialExcluded: self.init(name: "InvalidStateError", message: ctap.localizedDescription)
            case CTAPError.unsupportedAlgorithm, CTAPError.unsupportedOption: self.init(name: "NotSupportedError", message: ctap.localizedDescription)
            default: self = .notAllowed(ctap.localizedDescription)
            }
        } else {
            self = .notAllowed(error.localizedDescription)
        }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}

// MARK: - Requests

enum ResidentKeyPreference: String {
    case required, preferred, discouraged
}

enum WebAuthnRules {
    /// A page may use its own host or a parent domain of it as the relying-party id, but not a bare top-level name.
    static func isValidRPID(_ id: String, forHost host: String) -> Bool {
        guard host == id || host.hasSuffix("." + id) else { return false }
        if id == "localhost" { return true }
        let digitsAndDots = id.allSatisfy { $0.isNumber || $0 == "." }
        return id.contains(".") && !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains(":") && !digitsAndDots
    }

    static func effectiveRPID(_ requested: String?, host: String) throws -> String {
        let host = host.lowercased()
        guard let requested = requested?.lowercased(), !requested.isEmpty else { return host }
        guard isValidRPID(requested, forHost: host) else {
            throw WebAuthnFailure(name: "SecurityError", message: "The relying party ID \u{201C}\(requested)\u{201D} is not valid for \(host).")
        }
        return requested
    }

    static func timeout(_ milliseconds: Any?) -> TimeInterval {
        let seconds = (milliseconds as? NSNumber).map { $0.doubleValue / 1000 } ?? 120
        return min(max(seconds, 20), 300)
    }

    static func bytes(_ value: Any?, _ what: String) throws -> Data {
        guard let text = value as? String, let data = Base64URL.decode(text) else {
            throw WebAuthnFailure.typeError("\(what) must be a buffer.")
        }
        return data
    }

    /// A credential may be on a USB key unless it says it is only on the device itself or a phone.
    static func mayBeOnUSBKey(_ descriptor: [String: Any]) -> Bool {
        let transports = descriptor["transports"] as? [String] ?? []
        return transports.isEmpty || transports.contains { !["internal", "hybrid"].contains($0) }
    }

    static func credentialIDs(_ value: Any?) -> [Data] {
        (value as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }
    }

    /// The JSON a browser hands to the authenticator (and returns to the page), hashed with SHA-256 for signing.
    static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        let quoted = (try? JSONSerialization.data(withJSONObject: origin, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return Data("{\"type\":\"\(type)\",\"challenge\":\"\(Base64URL.encode(challenge))\",\"origin\":\(quoted),\"crossOrigin\":false}".utf8)
    }
}

struct GetRequest {
    var challenge: Data
    var rpId: String
    var allow: [Data]
    var userVerification: UserVerification
    var timeout: TimeInterval

    init(options: [String: Any], host: String) throws {
        challenge = try WebAuthnRules.bytes(options["challenge"], "challenge")
        rpId = try WebAuthnRules.effectiveRPID(options["rpId"] as? String, host: host)
        allow = WebAuthnRules.credentialIDs(options["allowCredentials"])
        userVerification = UserVerification(rawValue: options["userVerification"] as? String ?? "") ?? .preferred
        timeout = WebAuthnRules.timeout(options["timeout"])

        // Sites often try a Touch ID / iCloud passkey first. If every allowed credential lives only on the device
        // or on a phone, no USB key can help, so fail quietly and let the site fall back to something else.
        let listed = options["allowCredentials"] as? [[String: Any]] ?? []
        if !listed.isEmpty && !listed.contains(where: WebAuthnRules.mayBeOnUSBKey) {
            throw WebAuthnFailure.notAllowed("None of the allowed credentials can be on a USB security key.")
        }
    }
}

struct CreateRequest {
    var challenge: Data
    var rpId: String
    var rpName: String
    var userId: Data
    var userName: String
    var userDisplayName: String
    var algorithms: [Int]
    var exclude: [Data]
    var residentKey: ResidentKeyPreference
    var userVerification: UserVerification
    var attestation: String
    var timeout: TimeInterval
    var wantsCredProps: Bool

    init(options: [String: Any], host: String) throws {
        challenge = try WebAuthnRules.bytes(options["challenge"], "challenge")
        let rp = options["rp"] as? [String: Any] ?? [:]
        rpId = try WebAuthnRules.effectiveRPID(rp["id"] as? String, host: host)
        rpName = rp["name"] as? String ?? rpId

        let user = options["user"] as? [String: Any] ?? [:]
        userId = try WebAuthnRules.bytes(user["id"], "user.id")
        guard (1...64).contains(userId.count) else { throw WebAuthnFailure.typeError("user.id must be 1 to 64 bytes.") }
        userName = user["name"] as? String ?? ""
        userDisplayName = user["displayName"] as? String ?? userName

        let parameters = (options["pubKeyCredParams"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String) == "public-key" }
            .compactMap { ($0["alg"] as? NSNumber)?.intValue }
        if (options["pubKeyCredParams"] as? [Any])?.isEmpty == false && parameters.isEmpty {
            throw WebAuthnFailure(name: "NotSupportedError", message: "No supported public-key algorithm was requested.")
        }
        algorithms = parameters.isEmpty ? [-7, -257] : parameters
        exclude = WebAuthnRules.credentialIDs(options["excludeCredentials"])

        let selection = options["authenticatorSelection"] as? [String: Any] ?? [:]
        if (selection["authenticatorAttachment"] as? String) == "platform" {
            throw WebAuthnFailure.notAllowed("This site asked for a built-in authenticator (Touch ID or a passkey). Satellite can only use USB security keys.")
        }
        if let raw = selection["residentKey"] as? String, let preference = ResidentKeyPreference(rawValue: raw) {
            residentKey = preference
        } else {
            residentKey = (selection["requireResidentKey"] as? Bool) == true ? .required : .discouraged
        }
        userVerification = UserVerification(rawValue: selection["userVerification"] as? String ?? "") ?? .preferred
        attestation = options["attestation"] as? String ?? "none"
        timeout = WebAuthnRules.timeout(options["timeout"])
        wantsCredProps = (options["credProps"] as? Bool) == true
    }
}

// MARK: - Authenticator data

enum AuthenticatorData {
    /// The credential id and COSE public key inside the attested-credential part, if present.
    static func attestedCredential(_ data: Data) -> (id: Data, key: CBOR)? {
        let bytes = [UInt8](data)
        guard bytes.count > 55, bytes[32] & 0x40 != 0 else { return nil }
        let length = Int(bytes[53]) << 8 | Int(bytes[54])
        guard bytes.count >= 55 + length else { return nil }
        let id = Data(bytes[55..<55 + length])
        guard let (key, _) = try? CBOR.decodePrefix(Data(bytes[(55 + length)...])) else { return nil }
        return (id, key)
    }

    /// The DER SubjectPublicKeyInfo for an ES256 (P-256) COSE key, which is what `getPublicKey()` returns.
    static func spki(fromCOSE key: CBOR) -> (algorithm: Int, spki: Data?) {
        let algorithm = key[3]?.intValue ?? -7
        guard algorithm == -7, let x = key[-2]?.dataValue, let y = key[-3]?.dataValue, x.count == 32, y.count == 32 else {
            return (algorithm, nil)
        }
        let prefix: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                               0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04]
        return (algorithm, Data(prefix) + x + y)
    }

    static func coseKey(fromUncompressedPoint point: Data) -> CBOR? {
        guard point.count == 65, point[point.startIndex] == 0x04 else { return nil }
        return .map([
            (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
            (.int(-2), .bytes(Data(point[point.startIndex + 1..<point.startIndex + 33]))),
            (.int(-3), .bytes(Data(point[point.startIndex + 33..<point.startIndex + 65]))),
        ])
    }
}

// MARK: - Service

/// Runs WebAuthn requests against USB security keys. Only one request is handled at a time.
@MainActor
final class WebAuthnService {
    static let shared = WebAuthnService()
    private var tail: Task<Void, Never>?

    /// Runs `work` after every earlier request has finished.
    func serialized<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        tail = Task { _ = await task.value }
        return try await task.value.get()
    }

    // MARK: navigator.credentials.get

    func get(_ request: GetRequest, origin: String, host: String, prompt: SecurityKeyPrompt) async throws -> [String: Any] {
        let clientData = WebAuthnRules.clientDataJSON(type: "webauthn.get", challenge: request.challenge, origin: origin)
        let hash = Data(SHA256.hash(data: clientData))

        let assertion: Assertion = try await KeyRace<Assertion>(prompt: prompt) { device in
            let channel = try await self.open(device, prompt: prompt)
            if channel.supportsCBOR {
                let client = try await CTAP2Client.connect(channel) { retries, wrong in
                    await prompt.askPIN(site: host, retries: retries, wrong: wrong)
                }
                let found = try await client.getAssertions(
                    rpId: request.rpId, clientDataHash: hash, allow: request.allow, userVerification: request.userVerification)
                if found.count > 1, let chosen = await prompt.choose(site: host, from: found) { return chosen }
                guard let first = found.first else { throw CTAPError(code: CTAPError.noCredentials) }
                return first
            }
            // Older U2F-only key.
            let u2f = U2FClient(transport: channel)
            prompt.state = .touch
            let result = try await u2f.authenticate(
                appParam: Data(SHA256.hash(data: Data(request.rpId.utf8))), challengeParam: hash, allow: request.allow)
            let authData = Data(SHA256.hash(data: Data(request.rpId.utf8))) + Data([result.flags]) + result.counter
            return Assertion(credentialId: result.keyHandle, authenticatorData: authData, signature: result.signature)
        }.run(timeout: request.timeout)

        var response: [String: Any] = [:]
        response["clientDataJSON"] = Base64URL.encode(clientData)
        response["authenticatorData"] = Base64URL.encode(assertion.authenticatorData)
        response["signature"] = Base64URL.encode(assertion.signature)
        response["userHandle"] = assertion.userId.map { Base64URL.encode($0) } as Any? ?? NSNull()

        var result: [String: Any] = [:]
        result["id"] = Base64URL.encode(assertion.credentialId)
        result["rawId"] = Base64URL.encode(assertion.credentialId)
        result["type"] = "public-key"
        result["authenticatorAttachment"] = "cross-platform"
        result["response"] = response
        result["clientExtensionResults"] = [String: Any]()
        return result
    }

    // MARK: navigator.credentials.create

    func create(_ request: CreateRequest, origin: String, host: String, prompt: SecurityKeyPrompt) async throws -> [String: Any] {
        let clientData = WebAuthnRules.clientDataJSON(type: "webauthn.create", challenge: request.challenge, origin: origin)
        let hash = Data(SHA256.hash(data: clientData))
        let rpIdHash = Data(SHA256.hash(data: Data(request.rpId.utf8)))

        struct Made {
            var credential: MadeCredential
            var residentKey: Bool
        }

        let made: Made = try await KeyRace<Made>(prompt: prompt) { device in
            let channel = try await self.open(device, prompt: prompt)
            if channel.supportsCBOR {
                let client = try await CTAP2Client.connect(channel) { retries, wrong in
                    await prompt.askPIN(site: host, retries: retries, wrong: wrong)
                }
                let residentKey: Bool
                switch request.residentKey {
                case .required: residentKey = true
                case .preferred: residentKey = client.info.supportsResidentKeys
                case .discouraged: residentKey = false
                }
                let credential = try await client.makeCredential(MakeCredentialRequest(
                    clientDataHash: hash, rpId: request.rpId, rpName: request.rpName, userId: request.userId,
                    userName: request.userName, userDisplayName: request.userDisplayName, algorithms: request.algorithms,
                    exclude: request.exclude, residentKey: residentKey, userVerification: request.userVerification))
                return Made(credential: credential, residentKey: residentKey)
            }

            // Older U2F-only key: ES256 credentials that need no PIN and are not stored on the key.
            guard request.algorithms.contains(-7), request.residentKey != .required, request.userVerification != .required else {
                throw CTAPError(code: CTAPError.unsupportedOption)
            }
            prompt.state = .touch
            let registration = try await U2FClient(transport: channel)
                .register(appParam: rpIdHash, challengeParam: hash, exclude: request.exclude)
            guard let cose = AuthenticatorData.coseKey(fromUncompressedPoint: registration.publicKey) else {
                throw SecurityKeyError.protocolError("bad U2F public key")
            }
            var authData = rpIdHash + Data([0x41]) + Data(count: 4) + Data(count: 16)
            authData += Data([UInt8(registration.keyHandle.count >> 8), UInt8(registration.keyHandle.count & 0xFF)])
            authData += registration.keyHandle + cose.encoded()
            let statement = CBOR.map([(.text("sig"), .bytes(registration.signature)), (.text("x5c"), .array([.bytes(registration.certificate)]))])
            return Made(credential: MadeCredential(format: "fido-u2f", authenticatorData: authData, attestationStatement: statement), residentKey: false)
        }.run(timeout: request.timeout)

        var format = made.credential.format
        var statement = made.credential.attestationStatement
        if request.attestation == "none" {
            format = "none"
            statement = .map([])
        }
        let attestationObject = CBOR.map([
            (.text("fmt"), .text(format)), (.text("attStmt"), statement), (.text("authData"), .bytes(made.credential.authenticatorData)),
        ]).encoded()
        guard let attested = AuthenticatorData.attestedCredential(made.credential.authenticatorData) else {
            throw SecurityKeyError.protocolError("the key returned no credential")
        }
        let (algorithm, spki) = AuthenticatorData.spki(fromCOSE: attested.key)

        var response: [String: Any] = [:]
        response["clientDataJSON"] = Base64URL.encode(clientData)
        response["attestationObject"] = Base64URL.encode(attestationObject)
        response["authenticatorData"] = Base64URL.encode(made.credential.authenticatorData)
        response["transports"] = ["usb"]
        response["publicKeyAlgorithm"] = algorithm
        response["publicKey"] = spki.map { Base64URL.encode($0) } as Any? ?? NSNull()

        var extensions: [String: Any] = [:]
        if request.wantsCredProps { extensions["credProps"] = ["rk": made.residentKey] }

        var result: [String: Any] = [:]
        result["id"] = Base64URL.encode(attested.id)
        result["rawId"] = Base64URL.encode(attested.id)
        result["type"] = "public-key"
        result["authenticatorAttachment"] = "cross-platform"
        result["response"] = response
        result["clientExtensionResults"] = extensions
        return result
    }

    // MARK: Devices

    private func open(_ device: FIDODevice, prompt: SecurityKeyPrompt) async throws -> CTAPHIDChannel {
        let channel = CTAPHIDChannel(device: device)
        channel.onKeepalive = { status in
            if status == 2 { prompt.state = .touch }
        }
        try await channel.initialize()
        return channel
    }
}

/// Runs an operation on every connected security key at once (and on keys plugged in meanwhile); the first
/// key to succeed wins and the others are cancelled.
@MainActor
private final class KeyRace<Outcome> {
    private let prompt: SecurityKeyPrompt
    private let operation: (FIDODevice) async throws -> Outcome
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var watchers: [Task<Void, Never>] = []

    init(prompt: SecurityKeyPrompt, operation: @escaping (FIDODevice) async throws -> Outcome) {
        self.prompt = prompt
        self.operation = operation
    }

    func run(timeout: TimeInterval) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                self.continuation = continuation
                let monitor = FIDODeviceMonitor.shared
                monitor.start()
                prompt.state = monitor.devices.isEmpty ? .insert : .touch
                for device in monitor.devices { launch(device) }
                watchers.append(Task { @MainActor in
                    for await device in monitor.arrivals() { self.launch(device) }
                })
                watchers.append(Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.finish(.failure(WebAuthnFailure.notAllowed("The security key request timed out.")))
                })
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func launch(_ device: FIDODevice) {
        guard continuation != nil, tasks[device.id] == nil else { return }
        if prompt.state == .insert { prompt.state = .touch }
        tasks[device.id] = Task { @MainActor in
            do {
                finish(.success(try await operation(device)))
            } catch is CancellationError {
                return
            } catch let error as CTAPError where error.code == CTAPError.noCredentials {
                // This key isn't registered for the site: keep waiting in case the user tries another one.
                prompt.state = .wrongKey
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Outcome, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        tasks.values.forEach { $0.cancel() }
        watchers.forEach { $0.cancel() }
        tasks.removeAll()
        continuation.resume(with: result)
    }
}
