import AppKit
import Combine
import UserNotifications
import WebKit

// MARK: - Manifest

/// Chrome-style content-script manifest:
///   { "name": "...", "version": "1.0", "description": "...",
///     "matches": ["*://*.force.com/*"], "exclude_matches": [],
///     "js": ["content.js"], "css": ["style.css"],
///     "run_at": "document_start" | "document_end" | "document_idle",
///     "all_frames": false, "world": "isolated" | "main" }
struct ExtensionManifest: Decodable {
    var name: String
    var version: String?
    var description: String?
    var matches: [String]
    var excludeMatches: [String]?
    var js: [String]?
    var css: [String]?
    var runAt: String?
    var allFrames: Bool?
    var world: String?

    enum CodingKeys: String, CodingKey {
        case name, version, description, matches, js, css, world
        case excludeMatches = "exclude_matches"
        case runAt = "run_at"
        case allFrames = "all_frames"
    }
}

struct ExtensionInfo: Identifiable {
    let id: String
    let directory: URL
    var manifest: ExtensionManifest?
    var error: String?
    var isEnabled: Bool

    var displayName: String { manifest?.name ?? id }
}

// MARK: - Match patterns

enum MatchPattern {
    struct Invalid: LocalizedError {
        let pattern: String
        var errorDescription: String? { "Invalid match pattern \u{201C}\(pattern)\u{201D}" }
    }

    /// Converts a Chrome match pattern into a JavaScript RegExp source that is
    /// tested against `protocol//hostname + pathname + search` (no port, no fragment).
    static func regexSource(_ pattern: String) throws -> String {
        if pattern == "<all_urls>" { return "^(https?|file)://.*$" }

        guard let separator = pattern.range(of: "://") else { throw Invalid(pattern: pattern) }
        let scheme = String(pattern[..<separator.lowerBound])
        let rest = pattern[separator.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { throw Invalid(pattern: pattern) }
        let host = String(rest[..<slash])
        let path = String(rest[slash...])

        var source = "^"
        switch scheme {
        case "*": source += "https?"
        case "http", "https", "file": source += scheme
        default: throw Invalid(pattern: pattern)
        }
        source += "://"

        if host == "*" {
            source += "[^/]*"
        } else if host.hasPrefix("*.") {
            let suffix = String(host.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { throw Invalid(pattern: pattern) }
            source += "([^/]+\\.)?" + escape(suffix)
        } else if host.isEmpty {
            guard scheme == "file" else { throw Invalid(pattern: pattern) }
        } else {
            guard !host.contains("*") else { throw Invalid(pattern: pattern) }
            source += escape(host)
        }

        source += path.map { $0 == "*" ? ".*" : escape(String($0)) }.joined()
        return source + "$"
    }

    private static func escape(_ text: String) -> String {
        let special = Set("\\^$.|?*+()[]{}/")
        return text.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

// MARK: - Manager

final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    /// Shared by every web view so extension scripts apply app-wide.
    let userContentController = WKUserContentController()

    @Published private(set) var extensions: [ExtensionInfo] = []

    private var installedWorlds: [WKContentWorld] = []

    var directory: URL { AppPaths.extensions }

    func reload() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []

        extensions = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Self.scan($0, enabled: Self.storedEnabled($0.lastPathComponent)) }

        install()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey(id))
        if let index = extensions.firstIndex(where: { $0.id == id }) {
            extensions[index].isEnabled = enabled
        }
        install()
    }

    func installSampleExtension() {
        let dir = directory.appendingPathComponent("hello-badge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.sampleManifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? Self.sampleScript.write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        reload()
    }

    // MARK: Scanning

    private static func defaultsKey(_ id: String) -> String { "extension.enabled.\(id)" }

    private static func storedEnabled(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: defaultsKey(id)) as? Bool ?? true
    }

    private static func scan(_ dir: URL, enabled: Bool) -> ExtensionInfo {
        var info = ExtensionInfo(id: dir.lastPathComponent, directory: dir, manifest: nil, error: nil, isEnabled: enabled)
        do {
            let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
            guard !manifest.matches.isEmpty else { throw ExtensionError("\u{201C}matches\u{201D} is empty") }
            guard !(manifest.js ?? []).isEmpty || !(manifest.css ?? []).isEmpty else {
                throw ExtensionError("needs at least one \u{201C}js\u{201D} or \u{201C}css\u{201D} file")
            }
            for pattern in manifest.matches + (manifest.excludeMatches ?? []) { _ = try MatchPattern.regexSource(pattern) }
            _ = try buildSource(id: info.id, directory: dir, manifest: manifest)
            info.manifest = manifest
        } catch let error as DecodingError {
            info.error = "manifest.json: \(describe(error))"
        } catch {
            info.error = error.localizedDescription
        }
        return info
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing \u{201C}\(key.stringValue)\u{201D}"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.debugDescription
        @unknown default: return "unreadable"
        }
    }

    // MARK: Installation

    private func install() {
        userContentController.removeAllUserScripts()
        for world in installedWorlds { userContentController.removeAllScriptMessageHandlers(from: world) }
        installedWorlds.removeAll()

        for info in extensions where info.isEnabled && info.error == nil {
            guard let manifest = info.manifest,
                  let source = try? Self.buildSource(id: info.id, directory: info.directory, manifest: manifest)
            else { continue }

            let world: WKContentWorld
            if manifest.world == "main" {
                world = .page
            } else {
                world = .world(name: "satellite.ext.\(info.id)")
                userContentController.addScriptMessageHandler(
                    ExtensionBridge(extensionID: info.id), contentWorld: world, name: "satellite")
                installedWorlds.append(world)
            }

            let time: WKUserScriptInjectionTime = manifest.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
            userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: time, forMainFrameOnly: !(manifest.allFrames ?? false), in: world))
        }
    }

    // MARK: Script generation

    private struct ExtensionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func readFiles(_ names: [String], in dir: URL) throws -> String {
        let root = dir.standardizedFileURL.path + "/"
        return try names.map { name in
            let url = dir.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(root) else { throw ExtensionError("\u{201C}\(name)\u{201D} is outside the extension folder") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ExtensionError("can\u{2019}t read \u{201C}\(name)\u{201D}") }
            return text
        }.joined(separator: "\n;\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func buildSource(id: String, directory: URL, manifest: ExtensionManifest) throws -> String {
        let code = try readFiles(manifest.js ?? [], in: directory)
        let styles = try readFiles(manifest.css ?? [], in: directory)
        let includes = try manifest.matches.map { try MatchPattern.regexSource($0) }
        let excludes = try (manifest.excludeMatches ?? []).map { try MatchPattern.regexSource($0) }
        let isolated = manifest.world != "main"
        let idle = manifest.runAt == "document_idle"

        let bridge = isolated ? """
        const satellite = (() => {
          const post = (method, params) => window.webkit.messageHandlers.satellite.postMessage({ method, params: params || {} });
          return Object.freeze({
            extensionId: \(json(id)),
            storage: Object.freeze({
              get: key => post('storage.get', { key: String(key) }),
              set: (key, value) => post('storage.set', { key: String(key), value: value === undefined ? null : value }),
              remove: key => post('storage.remove', { key: String(key) }),
            }),
            notify: (title, body) => post('notify', { title: String(title), body: String(body || '') }),
            openExternal: url => post('openExternal', { url: String(url) }),
          });
        })();
        """ : ""

        let launch = idle ? """
        const __idle = () => ('requestIdleCallback' in window) ? requestIdleCallback(__run) : setTimeout(__run, 0);
        if (document.readyState === 'complete') { __idle(); } else { window.addEventListener('load', __idle, { once: true }); }
        """ : "__run();"

        return """
        (function () {
          const __includes = \(json(includes)).map(s => new RegExp(s));
          const __excludes = \(json(excludes)).map(s => new RegExp(s));
          const __url = location.protocol + '//' + location.hostname + location.pathname + location.search;
          if (!__includes.some(r => r.test(__url)) || __excludes.some(r => r.test(__url))) return;
          \(bridge)
          const __css = \(json(styles));
          if (__css) {
            const style = document.createElement('style');
            style.textContent = __css;
            const parent = document.head || document.documentElement;
            if (parent) parent.appendChild(style);
            else document.addEventListener('DOMContentLoaded', () => document.head.appendChild(style), { once: true });
          }
          const __run = async function () {
            try {
        \(code)
            } catch (error) { console.error('[satellite:' + \(json(id)) + ']', error); }
          };
          \(launch)
        })();
        //# sourceURL=satellite-extension-\(id).js
        """
    }

    // MARK: Sample

    private static let sampleManifest = """
    {
      "name": "Hello Badge",
      "version": "1.0",
      "description": "Shows a small badge on Salesforce pages and counts visits.",
      "matches": ["*://*.force.com/*", "*://*.salesforce.com/*"],
      "js": ["content.js"],
      "run_at": "document_idle",
      "world": "isolated"
    }

    """

    private static let sampleScript = """
    // Runs in an isolated world: full DOM access, plus the `satellite` API.
    // (Use "world": "main" in the manifest to reach page JavaScript instead; no `satellite` API there.)
    if (window.top === window) {
      const visits = ((await satellite.storage.get('visits')) || 0) + 1;
      await satellite.storage.set('visits', visits);

      const badge = document.createElement('div');
      badge.textContent = 'Satellite extension active \\u00B7 visit ' + visits;
      badge.style.cssText =
        'position:fixed;bottom:8px;left:8px;z-index:2147483647;padding:4px 8px;' +
        'background:#0b5cab;color:#fff;font:12px -apple-system,sans-serif;border-radius:6px;opacity:.85';
      document.body.appendChild(badge);
    }

    """
}

// MARK: - Bridge and storage

/// Native side of the `satellite` API. One instance per extension, registered only
/// in that extension's isolated content world so page scripts can't reach it.
final class ExtensionBridge: NSObject, WKScriptMessageHandlerWithReply {
    let extensionID: String

    init(extensionID: String) {
        self.extensionID = extensionID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return replyHandler(nil, "Malformed message")
        }
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "storage.get":
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            replyHandler(ExtensionStorage.shared.value(extensionID, key), nil)

        case "storage.set":
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            do {
                try ExtensionStorage.shared.setValue(params["value"] ?? NSNull(), extensionID, key)
                replyHandler(nil, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

        case "storage.remove":
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            do {
                try ExtensionStorage.shared.removeValue(extensionID, key)
                replyHandler(nil, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

        case "openExternal":
            guard let text = params["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return replyHandler(nil, "Only http(s) URLs can be opened")
            }
            NSWorkspace.shared.open(url)
            replyHandler(nil, nil)

        case "notify":
            Self.notify(title: params["title"] as? String ?? "", body: params["body"] as? String ?? "")
            replyHandler(nil, nil)

        default:
            replyHandler(nil, "Unknown method \(method)")
        }
    }

    private static func notify(title: String, body: String) {
        // UNUserNotificationCenter traps when the process isn't a bundled app.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("Satellite: notification skipped (not running as an app bundle): \(title)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

final class ExtensionStorage {
    static let shared = ExtensionStorage()

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private var cache: [String: [String: Any]] = [:]

    func value(_ id: String, _ key: String) -> Any? { load(id)[key] }

    func setValue(_ value: Any, _ id: String, _ key: String) throws {
        var dict = load(id)
        dict[key] = value
        try persist(dict, id)
    }

    func removeValue(_ id: String, _ key: String) throws {
        var dict = load(id)
        dict.removeValue(forKey: key)
        try persist(dict, id)
    }

    private func fileURL(_ id: String) -> URL {
        AppPaths.extensionData.appendingPathComponent("\(id).json")
    }

    private func load(_ id: String) -> [String: Any] {
        if let cached = cache[id] { return cached }
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL(id)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = object
        }
        cache[id] = dict
        return dict
    }

    private func persist(_ dict: [String: Any], _ id: String) throws {
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw Failure(errorDescription: "Value is not JSON-serializable")
        }
        try JSONSerialization.data(withJSONObject: dict).write(to: fileURL(id), options: .atomic)
        cache[id] = dict
    }
}
