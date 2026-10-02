import AppKit
import Security
import SecurityInterface

typealias ChallengeCompletion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

/// Answers TLS client-certificate challenges (mutual TLS, smart cards, MDM-issued device certs).
/// Shows the native macOS identity picker, then remembers the choice per host through the
/// keychain identity-preference mechanism Safari uses, so the prompt appears once.
final class ClientCertificateHandler: NSObject {
    static let shared = ClientCertificateHandler()

    private var chosen: [String: URLCredential] = [:]
    private var waiting: [String: [ChallengeCompletion]] = [:]
    private var activePickers: [IdentityPickerCoordinator] = []

    func handle(_ challenge: URLAuthenticationChallenge, window: NSWindow?, completion: @escaping ChallengeCompletion) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return completion(.performDefaultHandling, nil)
        }

        let host = space.host.lowercased()
        let preferenceName = Self.preferenceName(host)
        let issuers = space.distinguishedNames ?? []

        if challenge.previousFailureCount > 0 {
            // The server rejected what we sent last time: forget it and ask again.
            chosen[host] = nil
            SecIdentitySetPreferred(nil, preferenceName, nil)
        } else if let credential = chosen[host] {
            return completion(.useCredential, credential)
        }

        if waiting[host] != nil {
            waiting[host]?.append(completion)
            return
        }
        waiting[host] = [completion]

        if challenge.previousFailureCount == 0,
           let preferred = SecIdentityCopyPreferred(preferenceName, nil, issuers.isEmpty ? nil : issuers as CFArray) {
            return finish(host: host, identity: preferred, remember: false)
        }

        var identities = Self.identities(matchingIssuers: issuers)
        if identities.isEmpty && !issuers.isEmpty {
            // The issuer filter can be too strict for some chains; let the user choose from everything.
            identities = Self.identities(matchingIssuers: [])
        }
        guard !identities.isEmpty else {
            return finish(host: host, identity: nil, remember: false)
        }

        pickIdentity(from: identities, host: host, window: window ?? NSApp.keyWindow ?? NSApp.mainWindow) { [weak self] identity in
            self?.finish(host: host, identity: identity, remember: true)
        }
    }

    private static func preferenceName(_ host: String) -> CFString {
        "https://\(host)" as CFString
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

    private func finish(host: String, identity: SecIdentity?, remember: Bool) {
        let completions = waiting.removeValue(forKey: host) ?? []
        guard let identity else {
            // No identity available or the user cancelled: WebKit shows its "requires a client certificate" page.
            completions.forEach { $0(.performDefaultHandling, nil) }
            return
        }
        let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
        chosen[host] = credential
        if remember { SecIdentitySetPreferred(identity, Self.preferenceName(host), nil) }
        completions.forEach { $0(.useCredential, credential) }
    }

    private func pickIdentity(from identities: [SecIdentity], host: String, window: NSWindow?,
                              completion: @escaping (SecIdentity?) -> Void) {
        guard let panel = SFChooseIdentityPanel.shared() else { return completion(nil) }
        panel.setAlternateButtonTitle("Cancel")
        let message = "Choose a certificate to identify yourself to \(host)."

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
