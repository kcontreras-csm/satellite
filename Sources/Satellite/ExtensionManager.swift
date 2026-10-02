import AppKit
import Combine
import UserNotifications
import WebKit

struct ExtensionInfo: Identifiable {
    let id: String
    let directory: URL
    var manifest: ExtensionManifest?
    var error: String?
    var isEnabled: Bool
    var origin: ExtensionOrigin?
    /// For libraries: enabled extensions that currently load this library.
    var usedBy: [String] = []

    var displayName: String { manifest?.name ?? id }
    var version: SemVer? { manifest.map(\.semver) }
    var isLibrary: Bool { manifest?.isLibrary ?? false }
    var hasBackground: Bool { manifest?.background != nil }
    /// Content-script extensions that are enabled and healthy are injected into pages.
    var isActive: Bool { isEnabled && error == nil && manifest?.isLibrary == false }
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
    private var backgrounds: [String: BackgroundHost] = [:]
    /// extension id -> ids of the libraries it loads, dependencies first.
    private var libraryOrder: [String: [String]] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: ExtensionSettings.changed, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String, let key = note.userInfo?["key"] as? String,
                  let value = note.userInfo?["value"] else { return }
            self?.emit(id, type: "settings", arguments: [key, value])
        }
    }

    static func worldName(_ id: String) -> String { "satellite.ext.\(id)" }

    /// Settings declared in the extension's manifest.
    func declaredSettings(_ id: String) -> [SettingDefinition] { info(id)?.manifest?.settings ?? [] }

    /// Declared settings followed by any the extension registered from JavaScript.
    func settingsSchema(_ id: String) -> [SettingDefinition] { declaredSettings(id) + ExtensionSettings.shared.dynamicSchema(id) }

    /// Calls `window.__satelliteEmit(type, ...arguments)` inside the extension's world in every page it is
    /// running in (main frames) and in its background page.
    func emit(_ id: String, type: String, arguments: [Any]) {
        guard let info = info(id), info.isActive, info.manifest?.world != "main" else { return }
        let script = "window.__satelliteEmit && window.__satelliteEmit(\(Self.json(type)), \(Self.json(arguments)))"
        let world = WKContentWorld.world(name: Self.worldName(id))
        var views = WebPane.liveWebViews.allObjects
        if let background = backgrounds[id] { views.append(background.webView) }
        for view in views { view.evaluateJavaScript(script, in: nil, in: world) { _ in } }
    }

    var directory: URL { AppPaths.extensions }

    func info(_ id: String) -> ExtensionInfo? { extensions.first { $0.id == id } }

    func reload() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []

        var scanned = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Self.scan($0, enabled: Self.storedEnabled($0.lastPathComponent)) }

        libraryOrder = Self.resolveDependencies(&scanned)
        extensions = scanned
        install()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey(id))
        reload()
    }

    /// Extensions (any state) whose manifest lists `id` as a dependency.
    func dependents(of id: String) -> [ExtensionInfo] {
        extensions.filter { $0.manifest?.dependencies.keys.contains(id) == true }
    }

    /// Moves the extension folder to the Trash (recoverable) and forgets its saved data and settings.
    func uninstall(_ id: String, deleteData: Bool = true) throws {
        guard let info = info(id) else { return }
        let blockers = dependents(of: id).map(\.displayName)
        if !blockers.isEmpty {
            throw ManifestError("\u{201C}\(info.displayName)\u{201D} is required by \(blockers.joined(separator: ", ")). Remove those first.")
        }
        try FileManager.default.trashItem(at: info.directory, resultingItemURL: nil)
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(id))
        if deleteData {
            ExtensionStorage.shared.deleteAll(id)
            ExtensionSettings.shared.deleteAll(id)
        }
        reload()
    }

    func installSampleExtension() {
        let dir = directory.appendingPathComponent("sample-hello", isDirectory: true)
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
        var info = ExtensionInfo(
            id: dir.lastPathComponent, directory: dir, manifest: nil, error: nil,
            isEnabled: enabled, origin: ExtensionOrigin.read(from: dir))
        do {
            let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
            let manifest = try ExtensionManifest.parse(data, folderName: info.id)
            if let problem = manifest.compatibilityProblem { throw ManifestError(problem) }
            _ = try readFiles(manifest.codeFiles, in: dir)
            info.manifest = manifest
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            info.error = "manifest.json not found"
        } catch {
            info.error = error.localizedDescription
        }
        return info
    }

    /// Fills in `usedBy`, flags extensions whose dependencies are missing/incompatible/circular,
    /// and returns each healthy extension's library load order.
    private static func resolveDependencies(_ list: inout [ExtensionInfo]) -> [String: [String]] {
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })

        func collect(_ id: String, path: [String]) throws -> [String] {
            guard let manifest = byID[id]?.manifest else { return [] }
            var ordered: [String] = []
            for (depID, range) in manifest.dependencyRanges {
                guard let dep = byID[depID] else {
                    throw ManifestError("requires \u{201C}\(depID)\u{201D} \(range), which is not installed")
                }
                guard let depManifest = dep.manifest else {
                    throw ManifestError("requires \u{201C}\(depID)\u{201D}, which is broken: \(dep.error ?? "unreadable")")
                }
                guard depManifest.isLibrary else {
                    throw ManifestError("\u{201C}\(depID)\u{201D} is not a library and cannot be a dependency")
                }
                guard range.contains(depManifest.semver) else {
                    throw ManifestError("requires \u{201C}\(depID)\u{201D} \(range), but \(depManifest.version) is installed")
                }
                guard !path.contains(depID), depID != id else {
                    throw ManifestError("circular dependency: " + (path + [id, depID]).joined(separator: " \u{2192} "))
                }
                for item in try collect(depID, path: path + [id]) + [depID] where !ordered.contains(item) {
                    ordered.append(item)
                }
            }
            return ordered
        }

        var order: [String: [String]] = [:]
        for index in list.indices where list[index].error == nil {
            do {
                order[list[index].id] = try collect(list[index].id, path: [])
            } catch {
                list[index].error = error.localizedDescription
            }
        }
        for extensionInfo in list where extensionInfo.isActive {
            for libraryID in order[extensionInfo.id] ?? [] {
                if let i = list.firstIndex(where: { $0.id == libraryID }) { list[i].usedBy.append(extensionInfo.displayName) }
            }
        }
        return order
    }

    // MARK: Installation into web views

    private func install() {
        userContentController.removeAllUserScripts()
        for world in installedWorlds { userContentController.removeAllScriptMessageHandlers(from: world) }
        installedWorlds.removeAll()

        var runningBackgrounds = Set<String>()
        for info in extensions where info.isActive {
            guard let manifest = info.manifest else { continue }
            let libraries = (libraryOrder[info.id] ?? []).compactMap { id in extensions.first { $0.id == id } }
            let granted = Set(manifest.permissions + libraries.flatMap { $0.manifest?.permissions ?? [] })
            let world: WKContentWorld = manifest.world == "main" ? .page : .world(name: Self.worldName(info.id))

            if manifest.runsOnPages, let source = try? Self.buildSource(info: info, manifest: manifest, libraries: libraries, mode: .page) {
                if manifest.world != "main" {
                    userContentController.addScriptMessageHandler(
                        ExtensionBridge(extensionID: info.id, permissions: granted), contentWorld: world, name: "satellite")
                    installedWorlds.append(world)
                }
                let time: WKUserScriptInjectionTime = manifest.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
                userContentController.addUserScript(WKUserScript(
                    source: source, injectionTime: time, forMainFrameOnly: !manifest.allFrames, in: world))
            }

            if manifest.background != nil,
               let source = try? Self.buildSource(info: info, manifest: manifest, libraries: libraries, mode: .background) {
                runningBackgrounds.insert(info.id)
                let fingerprint = source + "|" + granted.map(\.rawValue).sorted().joined(separator: ",")
                if backgrounds[info.id]?.fingerprint != fingerprint {
                    backgrounds[info.id]?.stop()
                    backgrounds[info.id] = BackgroundHost(
                        extensionID: info.id, source: source, fingerprint: fingerprint, world: world,
                        bridge: ExtensionBridge(extensionID: info.id, permissions: granted))
                }
            }
        }

        for (id, host) in backgrounds where !runningBackgrounds.contains(id) {
            host.stop()
            backgrounds[id] = nil
        }
        UIRegistry.shared.prune(keeping: Set(extensions.filter(\.isActive).map(\.id)))
    }

    // MARK: Script generation

    private static func readFiles(_ names: [String], in dir: URL) throws -> String {
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try names.map { name in
            let url = dir.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root) else { throw ManifestError("\u{201C}\(name)\u{201D} is outside the extension folder") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ManifestError("can\u{2019}t read \u{201C}\(name)\u{201D}") }
            return text
        }.joined(separator: "\n;\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    enum ScriptMode {
        case page
        case background
    }

    private static func buildSource(info: ExtensionInfo, manifest: ExtensionManifest, libraries: [ExtensionInfo], mode: ScriptMode) throws -> String {
        let id = info.id
        let isolated = manifest.world != "main"

        let code: String
        var gate = ""
        var cssBlock = ""
        var launch = "__run();"
        if mode == .page {
            code = try readFiles(manifest.js, in: info.directory)
            var styleParts: [String] = []
            for library in libraries {
                if let m = library.manifest, !m.css.isEmpty { styleParts.append(try readFiles(m.css, in: library.directory)) }
            }
            if !manifest.css.isEmpty { styleParts.append(try readFiles(manifest.css, in: info.directory)) }
            let styles = styleParts.joined(separator: "\n")

            let includes = try manifest.matches.map { try MatchPattern.regexSource($0) }
            let excludes = try manifest.excludeMatches.map { try MatchPattern.regexSource($0) }
            gate = """
            const __includes = \(json(includes)).map(s => new RegExp(s));
              const __excludes = \(json(excludes)).map(s => new RegExp(s));
              const __url = location.protocol + '//' + location.hostname + location.pathname + location.search;
              if (!__includes.some(r => r.test(__url)) || __excludes.some(r => r.test(__url))) return;
            """
            cssBlock = """
            const __css = \(json(styles));
              if (__css) {
                const style = document.createElement('style');
                style.textContent = __css;
                const parent = document.head || document.documentElement;
                if (parent) parent.appendChild(style);
                else document.addEventListener('DOMContentLoaded', () => document.head.appendChild(style), { once: true });
              }
            """
            if manifest.runAt == "document_idle" {
                launch = """
                const __idle = () => ('requestIdleCallback' in window) ? requestIdleCallback(__run) : setTimeout(__run, 0);
                  if (document.readyState === 'complete') { __idle(); } else { window.addEventListener('load', __idle, { once: true }); }
                """
            }
        } else {
            code = try readFiles([manifest.background ?? ""], in: info.directory)
        }

        let bridge = isolated ? """
        const __listeners = { settings: [] };
          window.__satelliteEmit = (type, args) => {
            for (const callback of (__listeners[type] || [])) {
              try { callback(...args); } catch (error) { console.error('[satellite:' + \(json(id)) + ']', error); }
            }
          };
          const satellite = (() => {
            const clean = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
            const post = (method, params) => window.webkit.messageHandlers.satellite.postMessage({ method, params: params || {} });
            const list = section => Object.freeze({
              list: () => post('ui.list', { section }),
              add: item => post('ui.add', { section, item: clean(item) }),
              update: (id, patch) => post('ui.update', { section, id: String(id), patch: clean(patch) }),
              remove: id => post('ui.remove', { section, id: String(id) }),
              select: id => post('ui.select', { section, id: String(id) }),
            });
            return Object.freeze({
              extensionId: \(json(id)),
              storage: Object.freeze({
                get: key => post('storage.get', { key: String(key) }),
                set: (key, value) => post('storage.set', { key: String(key), value: value === undefined ? null : value }),
                remove: key => post('storage.remove', { key: String(key) }),
              }),
              notify: (title, body) => post('notify', { title: String(title), body: String(body || '') }),
              openExternal: url => post('openExternal', { url: String(url) }),
              ui: Object.freeze({ apps: list('apps'), assistants: list('assistants') }),
              settings: Object.freeze({
                get: key => post('settings.get', { key: String(key) }),
                getAll: () => post('settings.getAll'),
                set: (key, value) => post('settings.set', { key: String(key), value: clean(value) }),
                register: definitions => post('settings.register', { definitions: clean(Array.isArray(definitions) ? definitions : [definitions]) }),
                onChange: callback => { if (typeof callback === 'function') __listeners.settings.push(callback); },
              }),
            });
          })();
        """ : ""

        var modules = ""
        if !libraries.isEmpty {
            let definitions = try libraries.map { library -> String in
                let libraryCode = try readFiles(library.manifest?.js ?? [], in: library.directory)
                return "__define(\(json(library.id)), function (module, exports, require) {\n\(libraryCode)\n});"
            }.joined(separator: "\n")
            modules = """
            const __factories = Object.create(null), __loaded = Object.create(null);
              const __define = (name, factory) => { __factories[name] = factory; };
              const require = name => {
                if (name in __loaded) return __loaded[name].exports;
                const factory = __factories[name];
                if (!factory) throw new Error('Unknown library: ' + name);
                const module = { exports: {} };
                __loaded[name] = module;
                factory.call(module.exports, module, module.exports, require);
                return module.exports;
              };
              \(definitions)
            """
        }

        return """
        (function () {
          \(gate)
          \(bridge)
          \(cssBlock)
          \(modules)
          const __run = async function () {
            try {
        \(code)
            } catch (error) { console.error('[satellite:' + \(json(id)) + ']', error); }
          };
          \(launch)
        })();
        //# sourceURL=satellite-\(mode == .page ? "extension" : "background")-\(id).js
        """
    }

    // MARK: Sample

    private static let sampleManifest = """
    {
      "name": "Hello Badge (local sample)",
      "version": "1.0.0",
      "author": "Satellite",
      "description": "Shows a small badge on Salesforce pages and counts visits.",
      "icon": "symbol:hand.wave.fill",
      "matches": ["*://*.force.com/*", "*://*.salesforce.com/*"],
      "js": ["content.js"],
      "run_at": "document_idle",
      "world": "isolated",
      "permissions": ["storage"]
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
/// Every call is checked against the permissions the manifest declared.
final class ExtensionBridge: NSObject, WKScriptMessageHandlerWithReply {
    let extensionID: String
    let permissions: Set<ExtensionPermission>

    init(extensionID: String, permissions: Set<ExtensionPermission>) {
        self.extensionID = extensionID
        self.permissions = permissions
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return replyHandler(nil, "Malformed message")
        }
        let params = body["params"] as? [String: Any] ?? [:]

        func allowed(_ permission: ExtensionPermission) -> Bool {
            if permissions.contains(permission) { return true }
            replyHandler(nil, "Permission denied: add \u{201C}\(permission.rawValue)\u{201D} to \u{201C}permissions\u{201D} in manifest.json")
            return false
        }

        switch method {
        case "storage.get":
            guard allowed(.storage) else { return }
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            replyHandler(ExtensionStorage.shared.value(extensionID, key), nil)

        case "storage.set":
            guard allowed(.storage) else { return }
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            do {
                try ExtensionStorage.shared.setValue(params["value"] ?? NSNull(), extensionID, key)
                replyHandler(nil, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

        case "storage.remove":
            guard allowed(.storage) else { return }
            guard let key = params["key"] as? String else { return replyHandler(nil, "Missing key") }
            do {
                try ExtensionStorage.shared.removeValue(extensionID, key)
                replyHandler(nil, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

        case "openExternal":
            guard allowed(.openExternal) else { return }
            guard let text = params["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return replyHandler(nil, "Only http(s) URLs can be opened")
            }
            NSWorkspace.shared.open(url)
            replyHandler(nil, nil)

        case "notify":
            guard allowed(.notifications) else { return }
            Self.notify(title: params["title"] as? String ?? "", body: params["body"] as? String ?? "")
            replyHandler(nil, nil)

        case "ui.list", "ui.add", "ui.update", "ui.remove", "ui.select":
            guard allowed(.ui) else { return }
            guard let name = params["section"] as? String, let section = SidebarSection(rawValue: name) else {
                return replyHandler(nil, "Unknown list. Use apps or assistants.")
            }
            let registry = UIRegistry.shared
            let id = params["id"] as? String ?? ""
            do {
                switch method {
                case "ui.list": return replyHandler(registry.describe(section, for: extensionID), nil)
                case "ui.add": try registry.add(section, owner: extensionID, input: params["item"] as? [String: Any] ?? [:])
                case "ui.update": try registry.update(section, owner: extensionID, id: id, input: params["patch"] as? [String: Any] ?? [:])
                case "ui.remove": try registry.remove(section, owner: extensionID, id: id)
                default: try registry.requestSelect(section, owner: extensionID, id: id)
                }
                replyHandler(nil, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

        case "settings.get", "settings.getAll", "settings.set", "settings.register":
            let manager = ExtensionManager.shared
            let store = ExtensionSettings.shared
            let schema = manager.settingsSchema(extensionID)
            do {
                switch method {
                case "settings.getAll":
                    replyHandler(store.allValues(extensionID, schema: schema), nil)
                case "settings.get":
                    guard let key = params["key"] as? String, let definition = schema.first(where: { $0.key == key }) else {
                        throw ManifestError("Unknown setting \u{201C}\(params["key"] as? String ?? "")\u{201D}")
                    }
                    replyHandler(store.value(extensionID, definition).jsonObject, nil)
                case "settings.set":
                    guard let key = params["key"] as? String, let raw = params["value"], let value = SettingValue(any: raw) else {
                        throw ManifestError("A setting holds text, a number or true/false")
                    }
                    try store.set(extensionID, key: key, value: value, schema: schema)
                    replyHandler(nil, nil)
                default:
                    let data = try JSONSerialization.data(withJSONObject: params["definitions"] ?? [])
                    let definitions: [SettingDefinition]
                    do { definitions = try JSONDecoder().decode([SettingDefinition].self, from: data) }
                    catch { throw ManifestError("Invalid setting definition: each needs a key, a type (string, number, boolean or choice) and a title") }
                    try store.register(extensionID, definitions: definitions, declared: manager.declaredSettings(extensionID))
                    replyHandler(nil, nil)
                }
            } catch {
                replyHandler(nil, error.localizedDescription)
            }

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

    func deleteAll(_ id: String) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
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
