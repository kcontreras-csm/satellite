import AppKit
import ScreenCaptureKit

/// Screenshots of Satellite itself, for the MCP server's `take_screenshot`: every window it has on screen (the main
/// window, sheets and alerts, popovers, and open menus; WebKit draws a page's dropdowns and context menus as native
/// menus, so those come too), composited by the window server as they look, with no other app's windows. On macOS
/// 14.4 and later an app may capture its own windows without Screen Recording permission.
///
/// One capture of the display, limited to these windows, rather than one per window: a sheet's or a menu's window
/// captured alone comes back as its whole window group shrunk into its own frame.
///
/// Not on the main actor: while a menu is open, AppKit's menu tracking keeps the main thread from running Swift
/// tasks, so a capture that needed it would wait until the menu had closed and never show it.
enum AppScreenshot {
    struct Shot {
        let data: Data
        let mimeType: String
        let caption: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The long edge of the image, in pixels: beyond about this, an agent's model scales it down anyway.
    static let maxEdge: CGFloat = 1600
    /// Above this a PNG is sent as JPEG instead, to keep the answer quick to pass along.
    static let pngLimit = 2_500_000

    private struct OnScreen {
        let id: CGWindowID
        let frame: CGRect   // global, top-left origin, in points
        let layer: Int
    }

    static func capture() async throws -> Shot {
        // Front to back, with frames. A window's id, bounds and layer need no permission (its title would).
        let pid = getpid()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ours: [OnScreen] = info.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return OnScreen(id: id, frame: frame, layer: window[kCGWindowLayer as String] as? Int ?? 0)
        }
        guard let front = ours.first(where: { $0.layer == 0 }) ?? ours.first else {
            throw Failure("Satellite has no windows on screen (it may be hidden, minimized or on another Space), so there\u{2019}s nothing to capture.")
        }

        let content: SCShareableContent
        do {
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.currentProcess
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
        } catch {
            throw Failure("macOS didn\u{2019}t let Satellite capture its windows (\(error.localizedDescription)). Before macOS 14.4 this needs Screen Recording permission for Satellite in System Settings > Privacy & Security.")
        }
        // One display: the one most of the main window is on. Windows elsewhere are left out.
        let area = { (r: CGRect) in r.isNull ? 0 : r.width * r.height }
        guard let display = content.displays.max(by: { area($0.frame.intersection(front.frame)) < area($1.frame.intersection(front.frame)) }) else {
            throw Failure("macOS reported no display to capture.")
        }
        let shown = ours.filter { $0.frame.intersects(display.frame) }
        let windows = shown.compactMap { window in content.windows.first { $0.windowID == window.id } }
        guard !windows.isEmpty else { throw Failure("macOS returned none of Satellite\u{2019}s windows to capture.") }

        let union = shown.map(\.frame).reduce(shown[0].frame) { $0.union($1) }.intersection(display.frame)
        let filter = SCContentFilter(display: display, including: windows)
        let outputScale = min(CGFloat(filter.pointPixelScale), maxEdge / max(union.width, union.height))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = union.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)   // in the display's points
        configuration.width = Int((union.width * outputScale).rounded())
        configuration.height = Int((union.height * outputScale).rounded())
        configuration.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Failure("macOS couldn\u{2019}t capture Satellite\u{2019}s windows: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        var data = bitmap.representation(using: .png, properties: [:]) ?? Data()
        var mimeType = "image/png"
        if data.count > pngLimit, let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mimeType = "image/jpeg"
        }
        return Shot(data: data, mimeType: mimeType, caption: caption(shown, width: configuration.width, height: configuration.height))
    }

    /// Says what's in the picture, so an agent knows a menu or dialog is open.
    private static func caption(_ windows: [OnScreen], width: Int, height: Int) -> String {
        let menus = windows.filter { $0.layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) }.count
        let panels = windows.filter { $0.layer > 0 && $0.layer < Int(CGWindowLevelForKey(.popUpMenuWindow)) }.count
        let normal = windows.count - menus - panels
        var parts = ["\(normal) window\(normal == 1 ? "" : "s") or sheet\(normal == 1 ? "" : "s")"]
        if panels > 0 { parts.append("\(panels) floating panel\(panels == 1 ? "" : "s") or popover\(panels == 1 ? "" : "s")") }
        if menus > 0 { parts.append("\(menus) open menu\(menus == 1 ? "" : "s") (a context menu, a dropdown, or a menu bar menu)") }
        return "Screenshot of Satellite as it looks now, \(width)\u{00D7}\(height) px: " + parts.joined(separator: ", ")
            + ". Only Satellite\u{2019}s own windows are in it; other apps and the desktop are left out."
    }
}
