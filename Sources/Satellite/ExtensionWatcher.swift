import CoreServices
import Foundation
import WebKit

extension Notification.Name {
    /// Posted after files changed and extensions were reloaded. userInfo: "message" (String), "isError" (Bool).
    static let extensionsHotReloaded = Notification.Name("SatelliteExtensionsHotReloaded")
}

enum HotReloadDefaults {
    static let enabled = "hotReloadExtensions"
}

/// Hot reload. Watches every extension folder and, when files are saved, reloads the extension and (for
/// extensions you are developing) the open pages it applies to, so an edit shows up without any clicking.
@MainActor
final class ExtensionWatcher {
    static let shared = ExtensionWatcher()
    static let defaultsKey = HotReloadDefaults.enabled

    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var pending = Set<String>()
    private var debounce: Timer?
    private var started = false

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: DevelopmentFolders.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ExtensionManager.shared.reload(); ExtensionWatcher.shared.restart() }
        }
        restart()
    }

    /// Re-reads the list of folders and the on/off setting.
    func restart() {
        stop()
        guard isEnabled else { return }
        roots = ExtensionManager.shared.directories.compactMap { Self.realPath($0.path) }
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ExtensionWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let flagList = (0..<count).map { UInt32(flags[$0]) }
            MainActor.assumeIsolated { watcher.filesChanged(changed, flags: flagList) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        debounce?.invalidate()
        debounce = nil
        pending.removeAll()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: Events

    /// Collects which extensions were touched, ignoring editor and tooling noise, then waits for things to settle.
    func filesChanged(_ paths: [String], flags: [UInt32] = []) {
        let folderChanges = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        for (index, path) in paths.enumerated() {
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }
            // An extension folder itself "changing" just means something inside it did (which arrives as its own
            // event), so only a folder being added, removed or renamed counts.
            if parts.count == 1, index < flags.count, flags[index] & folderChanges == 0 { continue }
            if parts.contains(where: { $0.hasPrefix(".") && $0 != ".satellite.json" || $0 == "node_modules" }) { continue }
            // Editor backups and the temporary files that safe-saving writes next to the real one.
            if let name = parts.last, name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasSuffix(".tmp") || name.contains(".sb-") || name.contains("~.") { continue }
            pending.insert(first)
        }
        guard !pending.isEmpty else { return }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated { ExtensionWatcher.shared.flush() }
        }
    }

    private func flush() {
        let ids = pending.sorted()
        pending.removeAll()

        let manager = ExtensionManager.shared
        manager.reload()

        var messages: [String] = []
        var failed = false
        for id in ids {
            guard let info = manager.info(id) else { continue }   // deleted or renamed
            if let error = info.error {
                messages.append("\(info.displayName): \(error)")
                failed = true
                continue
            }
            messages.append("Reloaded \(info.displayName)")
            // Only extensions being developed reload the pages they run on; a store update doesn't disturb your work.
            if info.origin == nil, info.isActive, let manifest = info.manifest, manifest.runsOnPages {
                reloadPages(matching: manifest)
            }
        }
        guard !messages.isEmpty else { return }
        let text = messages.count > 2 ? "Reloaded \(messages.count) extensions" : messages.joined(separator: "  \u{00B7}  ")
        NotificationCenter.default.post(name: .extensionsHotReloaded, object: nil, userInfo: ["message": text, "isError": failed])
    }

    private func reloadPages(matching manifest: ExtensionManifest) {
        for view in WebPane.liveWebViews.allObjects {
            var urls = [view.url].compactMap { $0 }
            urls += FrameRegistry.shared.frames(of: view).compactMap { URL(string: $0.url) }
            if urls.contains(where: { MatchPattern.matches($0, patterns: manifest.matches, excludes: manifest.excludeMatches) }) {
                view.reload()
            }
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
