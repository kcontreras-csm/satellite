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

/// Answers TLS client-certificate challenges (mutual TLS, smart cards, MDM-issued device certs).
///
/// The first time a site asks, the native macOS certificate picker appears. The choice is remembered by the
/// certificate's fingerprint for the whole domain (every `*.example.com`), across launches, so later requests,
/// other subdomains and later sessions reuse it without asking. If a server rejects the remembered certificate
/// the memory for that site is dropped and the picker returns.
final class ClientCertificateHandler: NSObject {
    static let shared = ClientCertificateHandler()

    private struct Waiter {
        let host: String
        let completion: ChallengeCompletion
    }

    private let remembered = RememberedCertificates.shared
    /// Credentials already in use this session, keyed like `remembered` scopes.
    private var session: [String: URLCredential] = [:]
    /// Challenges waiting on an answer, grouped by domain so one prompt serves them all.
    private var waiting: [String: [Waiter]] = [:]
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
            // The server refused what we sent: forget it for this site and ask again.
            session[host] = nil
            session[domainScope] = nil
            remembered.remove(scope: host)
            remembered.remove(scope: domainScope)
        } else if let credential = session[host] ?? session[domainScope] {
            return completion(.useCredential, credential)
        }

        if waiting[domainScope] != nil {
            waiting[domainScope]?.append(Waiter(host: host, completion: completion))
            return
        }
        waiting[domainScope] = [Waiter(host: host, completion: completion)]

        let everything = Self.identities(matchingIssuers: [])

        // Remembered from an earlier session (or earlier today): use it without asking.
        if !afterRejection, let saved = remembered.entry(host: host, domainScope: domainScope),
           let identity = everything.first(where: { Self.fingerprint($0) == saved.fingerprint }) {
            return finish(domainScope: domainScope, identity: identity, remember: nil)
        }

        let issuers = space.distinguishedNames ?? []
        var candidates = issuers.isEmpty ? everything : Self.identities(matchingIssuers: issuers)
        if candidates.isEmpty { candidates = everything }  // the issuer filter can be stricter than the server really is
        guard !candidates.isEmpty else {
            return finish(domainScope: domainScope, identity: nil, remember: nil)
        }

        pickIdentity(from: candidates, host: host, window: window ?? NSApp.keyWindow ?? NSApp.mainWindow) { [weak self] identity in
            // After a rejection the new choice is specific to this host; otherwise it covers the domain.
            self?.finish(domainScope: domainScope, identity: identity, remember: afterRejection ? host : domainScope)
        }
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

    private static func identities(matchingIssuers issuers: [Data]) -> [SecIdentity] {
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
        return items.compactMap { item in
            CFGetTypeID(item) == SecIdentityGetTypeID() ? (item as! SecIdentity) : nil
        }
    }

    private static func certificate(_ identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess ? certificate : nil
    }

    private static func fingerprint(_ identity: SecIdentity) -> String? {
        guard let certificate = certificate(identity) else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    private static func name(_ identity: SecIdentity) -> String {
        certificate(identity).flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate"
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
