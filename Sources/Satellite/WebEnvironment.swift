import WebKit

enum WebEnvironment {
    // Makes WKWebView identify as Safari; Google sign-in (Gemini) and some other
    // sites reject the bare embedded-WebKit user agent.
    static let safariVersionToken = "Version/26.0 Safari/605.1.15"

    private static let salesforceFamily = [
        "salesforce.com", "force.com", "visualforce.com", "salesforce-setup.com", "my.site.com",
    ]

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = ExtensionManager.shared.userContentController
        config.applicationNameForUserAgent = safariVersionToken
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        return config
    }

    static func baseDomain(_ host: String) -> String {
        host.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
    }

    // Whether a link that wants a new window should stay inside Satellite
    // (same site, or part of the Salesforce family) instead of the default browser.
    static func isInternal(_ url: URL, from current: URL?) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if salesforceFamily.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if let currentHost = current?.host {
            return baseDomain(host) == baseDomain(currentHost)
        }
        return false
    }
}
