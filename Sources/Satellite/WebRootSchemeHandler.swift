import Foundation
import WebKit

/// Serves an extension's `web_root` folder at `satellite-ext://<extension id>/<path>`, so a sidebar item can open a
/// page the extension ships (a web app, a WebAssembly game) without a server.
///
/// - Only enabled, healthy extensions with a `web_root` are served, and only files inside that folder (symlinks that
///   lead out of it are refused).
/// - Only pages of the same extension can load its files: a website, or another extension's page, gets 403. The
///   page itself is the request whose main document is its own URL.
/// - The origin (`satellite-ext://<id>`) is a secure context with its own IndexedDB and localStorage, kept across
///   launches. It has no `satellite` API.
/// - Files are streamed in chunks off the main thread; single byte ranges are supported for media.
final class WebRootSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "satellite-ext"
    static let shared = WebRootSchemeHandler()

    private static let chunkSize = 1 << 20
    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "map": "application/json",
        "txt": "text/plain; charset=utf-8", "xml": "application/xml",
        "wasm": "application/wasm", "pck": "application/octet-stream", "bin": "application/octet-stream",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "ico": "image/x-icon",
        "ogg": "audio/ogg", "wav": "audio/wav", "mp3": "audio/mpeg", "mp4": "video/mp4", "webm": "video/webm",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    ]

    /// Tasks WebKit stopped (the page went away); reading stops for them. Main thread only.
    private var stopped = Set<ObjectIdentifier>()
    /// Concurrent, so a big file (a game's .wasm) doesn't hold up the others a page fetches at the same time.
    private let queue = DispatchQueue(label: "satellite.webroot", qos: .userInitiated, attributes: .concurrent)

    static func url(extensionID id: String, path: String = "") -> URL? {
        URL(string: "\(scheme)://\(id)/\(path)")
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        stopped.remove(ObjectIdentifier(task))
        let request = task.request
        guard let url = request.url, let id = url.host?.lowercased() else { return fail(task, 400, "Bad address") }

        // Only the extension's own pages: the page itself, or something it loads.
        guard let main = request.mainDocumentURL, main.scheme?.lowercased() == Self.scheme, main.host?.lowercased() == id else {
            return fail(task, 403, "Only \(id)'s own pages can load this")
        }
        guard let file = resolve(id: id, path: url.path) else { return fail(task, 404, "Not found") }

        let method = request.httpMethod?.uppercased() ?? "GET"
        let range = request.value(forHTTPHeaderField: "Range")
        let identifier = ObjectIdentifier(task)
        queue.async { [weak self] in
            self?.serve(file, url: url, method: method, range: range, task: task, identifier: identifier)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    // MARK: Files

    /// The file `path` names inside the extension's web root, if it's there and allowed.
    private func resolve(id: String, path: String) -> URL? {
        guard let info = ExtensionManager.shared.info(id), info.isEnabled, info.error == nil,
              let webRoot = info.manifest?.webRoot else { return nil }
        let root = info.directory.appendingPathComponent(webRoot, isDirectory: true).resolvingSymlinksInPath()

        var relative = path.removingPercentEncoding ?? path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        guard ExtensionManifest.isSafeRelativePath(relative) else { return nil }

        let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return candidate
    }

    /// Runs on `queue`. Every call into the task happens on the main thread, where WebKit started it.
    private func serve(_ file: URL, url: URL, method: String, range: String?, task: WKURLSchemeTask, identifier: ObjectIdentifier) {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue else {
            return DispatchQueue.main.async { self.fail(task, 404, "Not found") }
        }
        defer { try? handle.close() }

        var start = 0
        var end = size - 1
        var status = 200
        if let range {
            guard let bounds = Self.parseRange(range, size: size) else {
                let headers = ["Content-Range": "bytes */\(size)"]
                return DispatchQueue.main.async { self.fail(task, 416, "Range not satisfiable", headers: headers) }
            }
            (start, end, status) = (bounds.lowerBound, bounds.upperBound, 206)
        }
        let length = max(0, end - start + 1)

        var headers = [
            "Content-Type": Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream",
            "Content-Length": String(length),
            "Accept-Ranges": "bytes",
            // Saving a file and reloading shows the new version.
            "Cache-Control": "no-cache",
        ]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!

        var alive = true
        DispatchQueue.main.sync {
            alive = !self.stopped.contains(identifier)
            if alive { task.didReceive(response) }
        }
        guard alive else { return }

        if method != "HEAD" && length > 0 {
            do {
                try handle.seek(toOffset: UInt64(start))
                var remaining = length
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: min(Self.chunkSize, remaining)), !chunk.isEmpty else { break }
                    remaining -= chunk.count
                    DispatchQueue.main.sync {
                        alive = !self.stopped.contains(identifier)
                        if alive { task.didReceive(chunk) }
                    }
                    guard alive else { return }
                }
            } catch {
                return DispatchQueue.main.async {
                    guard !self.stopped.contains(identifier) else { return }
                    task.didFailWithError(error)
                }
            }
        }
        DispatchQueue.main.async {
            guard !self.stopped.contains(identifier) else { return }
            task.didFinish()
        }
    }

    /// One range of `bytes=a-b`, `bytes=a-` or `bytes=-n`; nil when it can't be served.
    static func parseRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let second = parts[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int(second), suffix > 0 else { return nil }
            return max(0, size - suffix)...(size - 1)
        }
        guard let start = Int(first), start < size else { return nil }
        let end = second.isEmpty ? size - 1 : min(Int(second) ?? -1, size - 1)
        return end >= start ? start...end : nil
    }

    private func fail(_ task: WKURLSchemeTask, _ status: Int, _ message: String, headers: [String: String] = [:]) {
        guard let url = task.request.url else { return }
        let body = Data(message.utf8)
        var fields = headers
        fields["Content-Type"] = "text/plain; charset=utf-8"
        fields["Content-Length"] = String(body.count)
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
        task.didReceive(body)
        task.didFinish()
    }
}
