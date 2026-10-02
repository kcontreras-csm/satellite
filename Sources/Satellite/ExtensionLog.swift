import Combine
import Foundation

/// Recent console output and errors from extension scripts, so they can be read inside Satellite
/// (Settings > Extensions > Logs) without opening a web inspector.
final class ExtensionLog: ObservableObject {
    static let shared = ExtensionLog()
    static let maxEntries = 300

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        /// log, info, warn, error or debug
        let level: String
        let message: String
        /// Where it ran: the page's host, or "background".
        let source: String
    }

    @Published private(set) var entries: [String: [Entry]] = [:]
    /// Errors nobody has looked at yet, per extension.
    @Published private(set) var unreadErrors: [String: Int] = [:]

    func record(_ extensionID: String, level: String, message: String, source: String) {
        let level = ["log", "info", "warn", "error", "debug"].contains(level) ? level : "log"
        var list = entries[extensionID] ?? []
        list.append(Entry(date: Date(), level: level, message: String(message.prefix(4000)), source: String(source.prefix(100))))
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        entries[extensionID] = list
        if level == "error" { unreadErrors[extensionID, default: 0] += 1 }
    }

    func markRead(_ extensionID: String) {
        if unreadErrors[extensionID] != nil { unreadErrors[extensionID] = nil }
    }

    func clear(_ extensionID: String) {
        entries[extensionID] = nil
        unreadErrors[extensionID] = nil
    }

    /// The whole log as plain text, for copying into a bug report or an AI chat.
    func text(for extensionID: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return (entries[extensionID] ?? []).map { "\(formatter.string(from: $0.date)) [\($0.level)] (\($0.source)) \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Extra folders Satellite loads extensions from, for working on extensions inside your own project folders.
enum DevelopmentFolders {
    static let defaultsKey = "developmentFolders"
    static let changed = Notification.Name("SatelliteDevelopmentFoldersChanged")

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        let path = url.standardizedFileURL.path
        guard !paths.contains(path), path != AppPaths.extensions.standardizedFileURL.path else { return }
        paths.append(path)
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
