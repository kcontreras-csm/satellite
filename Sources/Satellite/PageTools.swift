import AppKit
import WebKit

// MARK: - Zoom

enum ZoomChange {
    case larger
    case smaller
    case reset
}

/// The zoom levels Cmd+ and Cmd- step through, remembered per website so a page opens the way it was left.
enum ZoomStore {
    static let levels: [CGFloat] = [0.3, 0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let defaultsKey = "pageZoomByHost"

    static func level(forHost host: String?) -> CGFloat {
        guard let host, let value = UserDefaults.standard.dictionary(forKey: defaultsKey)?[host] as? Double else { return 1 }
        return CGFloat(value)
    }

    static func save(_ level: CGFloat, forHost host: String?) {
        guard let host else { return }
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[host] = abs(level - 1) < 0.001 ? nil : Double(level)
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    static func step(from current: CGFloat, _ change: ZoomChange) -> CGFloat {
        switch change {
        case .larger: return levels.first { $0 > current + 0.001 } ?? levels[levels.count - 1]
        case .smaller: return levels.last { $0 < current - 0.001 } ?? levels[0]
        case .reset: return 1
        }
    }
}

extension WebPane {
    /// Zooms the page one step (or back to 100%) and remembers it for the site. Returns the new level.
    @discardableResult
    func zoom(_ change: ZoomChange) -> CGFloat {
        let level = ZoomStore.step(from: webView.pageZoom, change)
        webView.pageZoom = level
        ZoomStore.save(level, forHost: webView.url?.host)
        return level
    }

    /// Called once a page starts to show, so each site keeps its own zoom.
    func applyStoredZoom() {
        let level = ZoomStore.level(forHost: webView.url?.host)
        if abs(webView.pageZoom - level) > 0.001 { webView.pageZoom = level }
    }
}

// MARK: - Printing

extension WebPane {
    func printPage(in window: NSWindow?) {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        // The operation lays the page out in this view, which is empty (and prints blank) until it has a size.
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

// MARK: - Links

extension WebPane {
    /// The address of what the pane shows, or (before it has loaded) the one it will open.
    var currentURL: URL? {
        guard didCreateView else { return homeURL }
        return webView.url ?? homeURL
    }
}

/// Copies a page's address. Plain text gets the address alone, or "title — address" with the title. The URL and its
/// title go along as their own types, and with the title an HTML link too, so rich editors (Slack, Docs, Mail)
/// paste the title, linked.
enum PageLink {
    static func copy(_ url: URL, title: String?, includeTitle: Bool, to pasteboard: NSPasteboard = .general) {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = url.absoluteString
        let item = NSPasteboardItem()
        item.setString(address, forType: .URL)
        if !name.isEmpty { item.setString(name, forType: NSPasteboard.PasteboardType("public.url-name")) }
        if includeTitle, !name.isEmpty {
            item.setString("\(name) \u{2014} \(address)", forType: .string)
            item.setString("<a href=\"\(escaped(address))\">\(escaped(name))</a>", forType: .html)
        } else {
            item.setString(address, forType: .string)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Only web addresses are worth copying or opening elsewhere (not about:blank or a page still starting).
    static func isShareable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// The right-click menu of a tab, or of an app in the rail: copy its page's link (with or without the title) or
    /// open it in the default browser, then any `extra` items.
    @MainActor
    static func menu(for pane: WebPane, window: NSWindow?, extra: [NSMenuItem] = [], pasteboard: NSPasteboard = .general) -> NSMenu {
        let menu = NSMenu()
        let url = pane.currentURL
        let title = pane.tabTitle
        let usable = isShareable(url)
        let copyLink = ClosureMenuItem(title: "Copy Link") {
            guard let url else { return }
            copy(url, title: title, includeTitle: false, to: pasteboard)
            Toast.show("Copied link", in: window)
        }
        let copyWithTitle = ClosureMenuItem(title: "Copy Link with Title") {
            guard let url else { return }
            copy(url, title: title, includeTitle: true, to: pasteboard)
            Toast.show("Copied \u{201C}\(title)\u{201D} with its link", in: window)
        }
        let open = ClosureMenuItem(title: "Open in Default Browser") {
            if let url { NSWorkspace.shared.open(url) }
        }
        for item in [copyLink, copyWithTitle, open] {
            item.isEnabled = usable
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }
}
