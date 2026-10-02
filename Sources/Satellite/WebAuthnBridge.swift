import WebKit

/// Connects `navigator.credentials.get/create` in web pages to USB security keys.
///
/// WKWebView refuses WebAuthn unless the app carries an Apple-issued browser entitlement, so Satellite
/// replaces those two calls with a script that asks this bridge. The bridge decides the page's origin itself
/// (from the frame WebKit reports, never from the page's claims), talks to the key, and hands back the result.
final class WebAuthnBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = WebAuthnBridge()
    static let handlerName = "satelliteWebAuthn"

    private var requests: [Int: Task<Void, Never>] = [:]

    /// Adds the page script and message handler. Safe to call repeatedly.
    func install(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String,
              let id = (body["id"] as? NSNumber)?.intValue else {
            return replyHandler(nil, "TypeError|Malformed request")
        }
        if op == "cancel" {
            requests[id]?.cancel()
            return replyHandler(nil, nil)
        }
        guard op == "get" || op == "create", let options = body["options"] as? [String: Any] else {
            return replyHandler(nil, "TypeError|Malformed request")
        }

        let origin: (string: String, host: String)
        do { origin = try Self.origin(of: message) } catch { return replyHandler(nil, Self.encode(error)) }
        let window = message.webView?.window

        requests[id] = Task { @MainActor in
            defer { requests[id] = nil }
            let prompt = SecurityKeyPrompt.shared
            do {
                let result: [String: Any] = try await WebAuthnService.shared.serialized {
                    // Parse first so a malformed request fails before any window appears.
                    let get = op == "get" ? try GetRequest(options: options, host: origin.host) : nil
                    let create = op == "create" ? try CreateRequest(options: options, host: origin.host) : nil
                    try Task.checkCancellation()

                    prompt.begin(site: origin.host, verb: op == "get" ? "sign in to" : "register with", over: window) { [weak self] in
                        self?.requests[id]?.cancel()
                    }
                    defer { prompt.end() }
                    if let get { return try await WebAuthnService.shared.get(get, origin: origin.string, host: origin.host, prompt: prompt) }
                    return try await WebAuthnService.shared.create(create!, origin: origin.string, host: origin.host, prompt: prompt)
                }
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, Self.encode(error))
            }
        }
    }

    private static func encode(_ error: Error) -> String {
        let failure = WebAuthnFailure(error)
        return "\(failure.name)|\(failure.message)"
    }

    /// The origin of the frame that made the request, as WebKit reports it.
    private static func origin(of message: WKScriptMessage) throws -> (string: String, host: String) {
        let frame = message.frameInfo.securityOrigin
        let scheme = frame.`protocol`.lowercased()
        let host = frame.host.lowercased()
        let secure = scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        guard !host.isEmpty, secure else {
            throw WebAuthnFailure(name: "SecurityError", message: "Security keys can only be used on secure (https) pages.")
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = frame.port == 0 ? defaultPort : frame.port

        if !message.frameInfo.isMainFrame {
            // A frame from another site would need permission from the page; only same-origin frames are allowed.
            guard let top = message.webView?.url, top.scheme?.lowercased() == scheme,
                  top.host?.lowercased() == host, (top.port ?? defaultPort) == port else {
                throw WebAuthnFailure.notAllowed("Security keys can\u{2019}t be used from a frame of a different site.")
            }
        }
        return ("\(scheme)://\(host)" + (port == defaultPort ? "" : ":\(port)"), host)
    }

    // MARK: Page script

    /// Replaces navigator.credentials.get/create for publicKey requests. Everything else, and conditional
    /// (autofill) requests, go to WebKit's own implementation.
    static let script = #"""
    (function () {
      'use strict';
      const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.satelliteWebAuthn;
      if (!bridge || !navigator.credentials || !window.PublicKeyCredential || window.__satelliteWebAuthn) return;
      Object.defineProperty(window, '__satelliteWebAuthn', { value: true });

      const proto = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!proto) return;
      const originalGet = proto.get;
      const originalCreate = proto.create;
      let nextId = 1;

      const toBytes = (source) => {
        if (source instanceof ArrayBuffer) return new Uint8Array(source);
        if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
        throw new TypeError('Expected a BufferSource');
      };
      const encode = (source) => {
        const bytes = toBytes(source);
        let binary = '';
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      };
      const decode = (text) => {
        const base64 = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4);
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes.buffer;
      };
      const descriptors = (list) => (list || []).map((d) => ({ id: encode(d.id), type: d.type, transports: d.transports || [] }));
      const define = (target, name, value) => Object.defineProperty(target, name, { value, enumerable: true, configurable: true });

      const failure = (error) => {
        const text = String((error && error.message) || error);
        const split = text.indexOf('|');
        const name = split < 0 ? 'NotAllowedError' : text.slice(0, split);
        const message = split < 0 ? text : text.slice(split + 1);
        return name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
      };

      const send = (op, options, signal) => {
        if (signal && signal.aborted) return Promise.reject(signal.reason || new DOMException('The operation was aborted.', 'AbortError'));
        const id = nextId++;
        let aborted = false;
        if (signal) {
          signal.addEventListener('abort', () => {
            aborted = true;
            bridge.postMessage({ op: 'cancel', id }).catch(() => {});
          }, { once: true });
        }
        return bridge.postMessage({ op, id, options: JSON.parse(JSON.stringify(options)) }).catch((error) => {
          if (aborted) throw signal.reason || new DOMException('The operation was aborted.', 'AbortError');
          throw failure(error);
        });
      };

      const build = (result, isCreate) => {
        const credential = Object.create(PublicKeyCredential.prototype);
        const responseClass = isCreate ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse;
        const response = Object.create((responseClass && responseClass.prototype) || Object.prototype);
        const r = result.response;
        define(response, 'clientDataJSON', decode(r.clientDataJSON));
        if (isCreate) {
          define(response, 'attestationObject', decode(r.attestationObject));
          define(response, 'getAuthenticatorData', () => decode(r.authenticatorData));
          define(response, 'getTransports', () => r.transports.slice());
          define(response, 'getPublicKeyAlgorithm', () => r.publicKeyAlgorithm);
          define(response, 'getPublicKey', () => (r.publicKey ? decode(r.publicKey) : null));
        } else {
          define(response, 'authenticatorData', decode(r.authenticatorData));
          define(response, 'signature', decode(r.signature));
          define(response, 'userHandle', r.userHandle ? decode(r.userHandle) : null);
        }
        define(credential, 'id', result.id);
        define(credential, 'rawId', decode(result.rawId));
        define(credential, 'type', 'public-key');
        define(credential, 'authenticatorAttachment', result.authenticatorAttachment);
        define(credential, 'response', response);
        define(credential, 'getClientExtensionResults', () => Object.assign({}, result.clientExtensionResults));
        define(credential, 'toJSON', () => ({
          id: result.id, rawId: result.rawId, type: 'public-key',
          authenticatorAttachment: result.authenticatorAttachment,
          response: r, clientExtensionResults: Object.assign({}, result.clientExtensionResults),
        }));
        return credential;
      };

      const get = function get(options) {
        const key = options && options.publicKey;
        if (!key || options.mediation === 'conditional') return originalGet.apply(this, arguments);
        try {
          return send('get', {
            challenge: encode(key.challenge), rpId: key.rpId, timeout: key.timeout,
            userVerification: key.userVerification, allowCredentials: descriptors(key.allowCredentials),
          }, options.signal).then((result) => build(result, false));
        } catch (error) { return Promise.reject(error); }
      };

      const create = function create(options) {
        const key = options && options.publicKey;
        if (!key) return originalCreate.apply(this, arguments);
        try {
          return send('create', {
            challenge: encode(key.challenge),
            rp: { id: key.rp && key.rp.id, name: key.rp && key.rp.name },
            user: { id: encode(key.user.id), name: key.user.name, displayName: key.user.displayName },
            pubKeyCredParams: (key.pubKeyCredParams || []).map((p) => ({ type: p.type, alg: p.alg })),
            excludeCredentials: descriptors(key.excludeCredentials),
            authenticatorSelection: key.authenticatorSelection || {},
            attestation: key.attestation, timeout: key.timeout,
            credProps: !!(key.extensions && key.extensions.credProps),
          }, options.signal).then((result) => build(result, true));
        } catch (error) { return Promise.reject(error); }
      };

      Object.defineProperty(proto, 'get', { value: get, configurable: true, writable: true });
      Object.defineProperty(proto, 'create', { value: create, configurable: true, writable: true });
    })();
    """#
}
