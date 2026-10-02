import AppKit
import CryptoKit
import Security
import SecurityInterface

typealias ChallengeCompletion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

/// A certificate choice Satellite remembers, so the picker only appears once.
struct RememberedCertificate: Codable, Hashable, Identifiable {
    /// A host ("mrshd.ssprod.sfdcbt.net") or every host under a domain ("*.sfdcbt.net").
    var scope: String
    /// SHA-256 of the certificate, used to find the same identity again.
    var fingerprint: String
    /// Readable name of the certificate, for Settings.
    var name: String

    var id: String { scope }
}

/// Persistent list of remembered certificate choices (UserDefaults), shown in Settings > General.
final class RememberedCertificates: ObservableObject {
    static let shared = RememberedCertificates()
    private static let defaultsKey = "rememberedClientCertificates"

    @Published private(set) var entries: [RememberedCertificate] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([RememberedCertificate].self, from: data) {
            entries = saved
        }
    }

    /// The choice for `host`: one made for that exact host wins over one made for its whole domain.
    func entry(host: String, domainScope: String) -> RememberedCertificate? {
        entries.first { $0.scope == host } ?? entries.first { $0.scope == domainScope }
    }

    func save(_ entry: RememberedCertificate) {
        entries.removeAll { $0.scope == entry.scope }
        entries.append(entry)
        entries.sort { $0.scope < $1.scope }
        persist()
    }

    func remove(scope: String) {
        entries.removeAll { $0.scope == scope }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }
}

/// A certificate (with its private key) that could be offered to a server.
struct CertificateCandidate {
    let identity: SecIdentity
    let fingerprint: String
    let name: String
}

/// What to do about a client-certificate request.
enum CertificateDecision {
    /// Use this certificate without asking.
    case use(CertificateCandidate)
    /// Several could work: let the user choose.
    case ask([CertificateCandidate])
    /// This Mac has no usable certificate.
    case none
}

/// Answers TLS client-certificate challenges (mutual TLS, smart cards, MDM-issued device certs).
///
/// Like other browsers, it only interrupts you when it has to. In order:
///  1. a certificate you chose before (remembered by fingerprint, for the whole domain);
///  2. a macOS identity preference for the site (what Safari honors, and device management can set);
///  3. the only valid certificate from an authority the server accepts;
///  4. on Salesforce domains, when several fit, the one from the authority the server lists first;
///  5. otherwise the native picker, and the choice is remembered.
/// If a server rejects what was sent, the memory for that site is dropped and the picker returns.
final class ClientCertificateHandler: NSObject {
    static let shared = ClientCertificateHandler()

    /// Sites where picking by the server's own ordering is safe to do without asking.
    private static let autoPickDomains = ["salesforce.com", "force.com", "sfdcbt.net", "sfdc.net", "sfdc.cl", "salesforce-setup.com", "visualforce.com"]

    private struct Waiter {
        let host: String
        let completion: ChallengeCompletion
    }

    private let remembered = RememberedCertificates.shared
    /// Credentials already in use this session, keyed like `remembered` scopes.
    private var session: [String: URLCredential] = [:]
    /// Challenges waiting on an answer, grouped by domain so one prompt serves them all.
    private var waiting: [String: [Waiter]] = [:]
    /// Hosts that rejected a certificate: no automatic choice for them until the user picks one.
    private var mustAsk: Set<String> = []
    /// Hosts for which no certificate of ours fits what they accept, so there is no need to work that out again
    /// for every connection.
    private var sendsNothing: [String: Date] = [:]
    private var activePickers: [IdentityPickerCoordinator] = []

    func handle(_ challenge: URLAuthenticationChallenge, window: NSWindow?, completion: @escaping ChallengeCompletion) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return completion(.performDefaultHandling, nil)
        }

        let host = space.host.lowercased()
        let domainScope = Self.domainScope(host)
        let afterRejection = challenge.previousFailureCount > 0

        if afterRejection {
            certificateRejected(host: host)
        } else if let credential = session[host] ?? session[domainScope] {
            return completion(.useCredential, credential)
        }

        if let until = sendsNothing[host], until > Date() {
            return completion(.performDefaultHandling, nil)
        }
        if waiting[domainScope] != nil {
            waiting[domainScope]?.append(Waiter(host: host, completion: completion))
            return
        }
        waiting[domainScope] = [Waiter(host: host, completion: completion)]

        switch decide(host: host, issuers: space.distinguishedNames ?? []) {
        case .use(let candidate):
            finish(domainScope: domainScope, identity: candidate.identity, remember: nil)
        case .none:
            sendsNothing[host] = Date().addingTimeInterval(300)
            finish(domainScope: domainScope, identity: nil, remember: nil)
        case .ask(let candidates):
            pickIdentity(from: candidates.map(\.identity), host: host, window: window ?? NSApp.keyWindow ?? NSApp.mainWindow) { [weak self] identity in
                guard let self else { return }
                // After a rejection the new choice is specific to this host; otherwise it covers the domain.
                let hostSpecific = self.mustAsk.contains(host)
                self.mustAsk.remove(host)
                self.finish(domainScope: domainScope, identity: identity, remember: hostSpecific ? host : domainScope)
            }
        }
    }

    /// Picks the certificate to offer `host`, or says that the user has to choose.
    func decide(host: String, issuers: [Data]) -> CertificateDecision {
        let valid = Self.candidates(matchingIssuers: [])
        guard !valid.isEmpty else { return .none }
        let automatic = !mustAsk.contains(host)

        if automatic {
            // 1. Something the user chose before.
            if let saved = remembered.entry(host: host, domainScope: Self.domainScope(host)),
               let match = valid.first(where: { $0.fingerprint == saved.fingerprint }) {
                return .use(match)
            }
            // 2. A macOS identity preference (Keychain Access > identity preferences, or set by device management).
            for name in ["https://\(host)", "https://\(host)/", host] {
                if let preferred = SecIdentityCopyPreferred(name as CFString, nil, issuers.isEmpty ? nil : issuers as CFArray),
                   let fingerprint = Self.fingerprint(preferred), let match = valid.first(where: { $0.fingerprint == fingerprint }) {
                    return .use(match)
                }
            }
        }

        // Which valid certificates does the server accept, in the order it lists its authorities?
        let fitting = issuers.isEmpty ? valid : Self.rank(valid, by: issuers)
        // The server named the authorities it trusts and none of our certificates chains to one of them. Browsers
        // offer nothing in that case and carry on (servers that don't insist on a certificate let the page load).
        if fitting.isEmpty { return .none }
        if automatic {
            if fitting.count == 1 { return .use(fitting[0]) }
            if issuers.isEmpty == false && Self.isAutoPickDomain(host) { return .use(fitting[0]) }
        }
        return .ask(fitting)
    }

    /// Called when a page failed because the server refused the certificate that was sent (or wanted one
    /// and got none): forget what was sent, so the next attempt lets the user choose.
    func certificateRejected(host: String) {
        let host = host.lowercased()
        let domainScope = Self.domainScope(host)
        sendsNothing[host] = nil
        session[host] = nil
        session[domainScope] = nil
        remembered.remove(scope: host)
        remembered.remove(scope: domainScope)
        mustAsk.insert(host)
    }

    /// Forgets a remembered choice (and the credential in use) so the picker appears again.
    func forget(scope: String) {
        remembered.remove(scope: scope)
        session[scope] = nil
    }

    func forgetAll() {
        remembered.removeAll()
        session.removeAll()
    }

    // MARK: Finishing

    private func finish(domainScope: String, identity: SecIdentity?, remember scope: String?) {
        let waiters = waiting.removeValue(forKey: domainScope) ?? []
        guard let identity else {
            // Nothing to offer, or the user cancelled: WebKit shows its "requires a client certificate" page.
            waiters.forEach { $0.completion(.performDefaultHandling, nil) }
            return
        }

        let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
        session[domainScope] = credential
        for waiter in waiters { session[waiter.host] = credential }

        if let scope, let fingerprint = Self.fingerprint(identity) {
            remembered.save(RememberedCertificate(scope: scope, fingerprint: fingerprint, name: Self.name(identity)))
        }
        waiters.forEach { $0.completion(.useCredential, credential) }
    }

    // MARK: Identities

    private static func domainScope(_ host: String) -> String {
        "*." + WebEnvironment.baseDomain(host)
    }

    private static func isAutoPickDomain(_ host: String) -> Bool {
        autoPickDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Identities from the keychain (optionally only those from the listed authorities) whose certificate is
    /// valid right now, without duplicates.
    private static func candidates(matchingIssuers issuers: [Data]) -> [CertificateCandidate] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        if !issuers.isEmpty { query[kSecMatchIssuers as String] = issuers }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [AnyObject] else {
            return []
        }
        var seen = Set<String>()
        var found: [CertificateCandidate] = []
        for item in items where CFGetTypeID(item) == SecIdentityGetTypeID() {
            let identity = item as! SecIdentity
            guard let fingerprint = fingerprint(identity), isValidNow(identity), seen.insert(fingerprint).inserted else { continue }
            found.append(CertificateCandidate(identity: identity, fingerprint: fingerprint, name: name(identity)))
        }
        return found
    }

    /// The certificates the server would accept, best first. A certificate fits when its chain reaches an authority the
    /// server lists (any link: the certificate's own issuer, an intermediate, or the root), and it ranks by where that
    /// authority sits in the server's list. Apple's issuer filter is added as a second opinion for the direct issuer,
    /// since it compares names more leniently than raw bytes.
    private static func rank(_ valid: [CertificateCandidate], by issuers: [Data]) -> [CertificateCandidate] {
        var direct: [String: Int] = [:]
        for (index, issuer) in issuers.enumerated() {
            for match in candidates(matchingIssuers: [issuer]) where direct[match.fingerprint] == nil { direct[match.fingerprint] = index }
        }

        var scored: [(candidate: CertificateCandidate, score: Int, order: Int)] = []
        for (order, candidate) in valid.enumerated() {
            let names = chainNames(of: candidate.identity)
            let viaChain = issuers.firstIndex { names.contains($0) }
            if let best = [viaChain, direct[candidate.fingerprint]].compactMap({ $0 }).min() {
                scored.append((candidate, best, order))
            }
        }
        return scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.candidate)
    }

    /// The DER names (issuer and subject) of every certificate in the identity's chain.
    private static func chainNames(of identity: SecIdentity) -> [Data] {
        guard let leaf = certificate(identity) else { return [] }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return [] }
        SecTrustSetNetworkFetchAllowed(trust, false)
        _ = SecTrustEvaluateWithError(trust, nil)  // builds the chain; whether it is trusted doesn't matter here
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [leaf]
        return chain.flatMap { cert -> [Data] in
            let (issuer, subject) = DER.issuerAndSubject(of: SecCertificateCopyData(cert) as Data)
            return [issuer, subject]
        }
    }

    private static func certificate(_ identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess ? certificate : nil
    }

    static func fingerprint(_ identity: SecIdentity) -> String? {
        guard let certificate = certificate(identity) else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    private static func name(_ identity: SecIdentity) -> String {
        certificate(identity).flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate"
    }

    private static func isValidNow(_ identity: SecIdentity) -> Bool {
        guard let certificate = certificate(identity) else { return false }
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] ?? [:]
        func date(_ oid: CFString) -> Date? {
            (values[oid as String]?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        let now = Date()
        if let start = date(kSecOIDX509V1ValidityNotBefore), start > now { return false }
        if let end = date(kSecOIDX509V1ValidityNotAfter), end < now { return false }
        return true
    }

    // MARK: Picker

    private func pickIdentity(from identities: [SecIdentity], host: String, window: NSWindow?,
                              completion: @escaping (SecIdentity?) -> Void) {
        guard let panel = SFChooseIdentityPanel.shared() else { return completion(nil) }
        panel.setAlternateButtonTitle("Cancel")
        let message = "Choose a certificate to identify yourself to \(host). Satellite will remember your choice."

        guard let window else {
            let response = panel.runModal(forIdentities: identities, message: message)
            completion(response == NSApplication.ModalResponse.OK.rawValue ? panel.identity()?.takeUnretainedValue() : nil)
            return
        }

        let coordinator = IdentityPickerCoordinator(panel: panel) { [weak self] identity in
            self?.activePickers.removeAll { $0.panel === panel && $0.isFinished }
            completion(identity)
        }
        activePickers.append(coordinator)
        panel.beginSheet(
            for: window, modalDelegate: coordinator,
            didEnd: #selector(IdentityPickerCoordinator.panelDidEnd(_:returnCode:contextInfo:)),
            contextInfo: nil, identities: identities, message: message)
    }
}

private final class IdentityPickerCoordinator: NSObject {
    let panel: SFChooseIdentityPanel
    private(set) var isFinished = false
    private let done: (SecIdentity?) -> Void

    init(panel: SFChooseIdentityPanel, done: @escaping (SecIdentity?) -> Void) {
        self.panel = panel
        self.done = done
    }

    @objc func panelDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        isFinished = true
        let identity = returnCode == NSApplication.ModalResponse.OK.rawValue ? panel.identity()?.takeUnretainedValue() : nil
        done(identity)
    }
}

/// Just enough DER to pull the issuer and subject names out of an X.509 certificate.
private enum DER {
    /// Reads the element at `offset`: where it ends and where its content starts.
    static func element(_ b: [UInt8], _ offset: Int) -> (end: Int, content: Int)? {
        guard offset + 2 <= b.count else { return nil }
        var length = Int(b[offset + 1])
        var content = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + 2 + count <= b.count else { return nil }
            length = 0
            for i in 0..<count { length = (length << 8) | Int(b[offset + 2 + i]) }
            content = offset + 2 + count
        }
        return content + length <= b.count ? (content + length, content) : nil
    }

    /// The DER-encoded issuer and subject names of a certificate (empty data if it can't be read).
    static func issuerAndSubject(of certificate: Data) -> (issuer: Data, subject: Data) {
        let b = [UInt8](certificate)
        guard let cert = element(b, 0), let tbs = element(b, cert.content) else { return (Data(), Data()) }
        var cursor = tbs.content
        if cursor < b.count, b[cursor] == 0xA0, let version = element(b, cursor) { cursor = version.end }
        var fields: [Data] = []  // serial, signature algorithm, issuer, validity, subject
        while fields.count < 5, cursor < tbs.end, let next = element(b, cursor) {
            fields.append(Data(b[cursor..<next.end]))
            cursor = next.end
        }
        return fields.count == 5 ? (fields[2], fields[4]) : (Data(), Data())
    }
}
