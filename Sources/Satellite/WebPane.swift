import AppKit
import WebKit

extension Notification.Name {
    static let webPaneStateChanged = Notification.Name("SatelliteWebPaneStateChanged")
}

/// Owns one WKWebView plus the navigation, UI and download delegates it needs
/// to behave like a real browser tab (popups, alerts, uploads, downloads).
final class WebPane: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private(set) var name: String
    private(set) var homeURL: URL?
    var onClose: (() -> Void)?

    private let providedConfiguration: WKWebViewConfiguration?
    private var didStartLoading = false
    private var observations: [NSKeyValueObservation] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    /// Every page web view that currently exists, so extension events can be delivered to them.
    static let liveWebViews = NSHashTable<WKWebView>.weakObjects()

    private(set) var didCreateView = false

    private(set) lazy var webView: WKWebView = {
        didCreateView = true
        let view = WKWebView(frame: .zero, configuration: providedConfiguration ?? WebEnvironment.makeConfiguration())
        WebPane.liveWebViews.add(view)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.translatesAutoresizingMaskIntoConstraints = false
        let notify = { [weak self] (_: WKWebView, _: Any) in
            guard let self else { return }
            NotificationCenter.default.post(name: .webPaneStateChanged, object: self)
        }
        observations = [
            view.observe(\.canGoBack, changeHandler: { v, c in notify(v, c) }),
            view.observe(\.canGoForward, changeHandler: { v, c in notify(v, c) }),
            view.observe(\.isLoading, changeHandler: { v, c in notify(v, c) }),
        ]
        return view
    }()

    init(name: String, url: URL?, configuration: WKWebViewConfiguration? = nil) {
        self.name = name
        self.homeURL = url
        self.providedConfiguration = configuration
        super.init()
    }

    func loadIfNeeded() {
        guard !didStartLoading, let homeURL else { return }
        didStartLoading = true
        webView.load(URLRequest(url: homeURL))
    }

    /// Applies a renamed or re-pointed sidebar item. A page that is already showing moves to the new address.
    func update(name: String, url: URL) {
        self.name = name
        guard url != homeURL else { return }
        homeURL = url
        if didStartLoading { webView.load(URLRequest(url: url)) }
    }

    /// Releases the web view of an item that was removed from the sidebar.
    func teardown() {
        guard didCreateView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        observations.removeAll()
    }

    func reloadIfLoaded() {
        guard didStartLoading else { return }
        webView.reload()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            // mailto:, tel:, slack:, etc. belong to other apps.
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }

        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download)
        }

        // Cross-site links that ask for a new window go to the default browser.
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType == .linkActivated,
           !WebEnvironment.isInternal(url, from: webView.url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping ChallengeCompletion) {
        ClientCertificateHandler.shared.handle(challenge, window: webView.window, completion: completionHandler)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping ChallengeCompletion) {
        ClientCertificateHandler.shared.handle(challenge, window: NSApp.keyWindow, completion: completionHandler)
    }

    private func showErrorPage(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Cancelled loads and policy-change interruptions (downloads) are not failures.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        let failing = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? webView.url?.absoluteString ?? ""
        // The server refused the certificate we sent (or wanted one and got none): don't send the same one again.
        if nsError.domain == NSURLErrorDomain,
           [NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired].contains(nsError.code),
           let host = URL(string: failing)?.host {
            ClientCertificateHandler.shared.certificateRejected(host: host)
        }
        let html = """
        <html><head><meta name="color-scheme" content="light dark">
        <style>body{font:15px -apple-system;display:flex;height:100vh;margin:0;align-items:center;justify-content:center;text-align:center}
        div{max-width:420px}h2{font-weight:600}p{opacity:.7}a{color:-apple-system-blue}</style></head>
        <body><div><h2>Can\u{2019}t open this page</h2><p>\(Self.escape(nsError.localizedDescription))</p>
        <p><a href="\(Self.escape(failing))">Try again</a></p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = PopupWindowController(configuration: configuration, features: windowFeatures)
        popup.show()
        return popup.pane.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message, frame: frame, buttons: ["OK"])
        present(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, frame: frame, buttons: ["OK", "Cancel"])
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(prompt, frame: frame, buttons: ["OK", "Cancel"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let handler: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    private func makeAlert(_ message: String, frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? name
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    private func present(_ alert: NSAlert, in webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = (suggestedFilename as NSString).lastPathComponent
        let destination = Self.uniqueURL(in: downloads, filename: safeName.isEmpty ? "download" : safeName)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Satellite: download failed: \(error.localizedDescription)")
    }

    private static func uniqueURL(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(filename)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

/// A window for script-opened popups (OAuth sign-in, Salesforce record windows).
final class PopupWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PopupWindowController] = []
    let pane: WebPane

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        pane = WebPane(name: "Popup", url: nil, configuration: configuration)
        let width = features.width?.doubleValue ?? 520
        let height = features.height?.doubleValue ?? 680
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(width, 320), height: max(height, 240)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.webView
        pane.webView.translatesAutoresizingMaskIntoConstraints = true
        pane.webView.autoresizingMask = [.width, .height]
        super.init(window: window)
        window.delegate = self
        pane.onClose = { [weak self] in self?.window?.close() }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        Self.open.append(self)
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
