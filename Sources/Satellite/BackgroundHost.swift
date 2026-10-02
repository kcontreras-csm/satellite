import WebKit

/// Runs an extension's background script in a hidden web view, so it can change the sidebar and react to
/// settings without any page being open. It has the same `satellite` API as content scripts, no access to
/// the user's logged-in sessions (its own throwaway data store), and ordinary web-platform limits
/// (cross-origin requests are subject to CORS, and timers may be throttled while it is hidden).
final class BackgroundHost: NSObject {
    let extensionID: String
    /// Identifies the script and permissions it was started with, so unchanged hosts are kept across reloads.
    let fingerprint: String
    let webView: WKWebView
    private let world: WKContentWorld

    init(extensionID: String, source: String, fingerprint: String, world: WKContentWorld, bridge: ExtensionBridge) {
        self.extensionID = extensionID
        self.fingerprint = fingerprint
        self.world = world

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(bridge, contentWorld: world, name: "satellite")
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()

        let page = "<!doctype html><html><head><title>\(extensionID) background</title></head><body></body></html>"
        webView.loadHTMLString(page, baseURL: URL(string: "https://background.satellite.invalid/\(extensionID)/"))
    }

    func stop() {
        webView.stopLoading()
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers(from: world)
        webView.loadHTMLString("", baseURL: nil)
    }
}
