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
