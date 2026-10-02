import Foundation

enum SidebarSection: String, CaseIterable {
    case apps
    case assistants
}

struct SidebarItem: Equatable, Identifiable {
    /// Unique within a section: the config id for built-in items, "<extension>/<local id>" for extension items.
    var id: String
    var name: String
    var url: URL
    /// SF Symbol name. Unknown names render as a globe.
    var symbol: String
    var badge: String?
    var hidden = false
    /// The extension that added this item; nil for items from config.json.
    var owner: String?

    init(_ app: WebApp) {
        id = app.id
        name = app.name
        url = app.url
        symbol = app.symbol
    }

    init(id: String, name: String, url: URL, symbol: String, badge: String?, owner: String) {
        self.id = id
        self.name = name
        self.url = url
        self.symbol = symbol
        self.badge = badge
        self.owner = owner
    }
}

/// A partial change to an item. `badge` is doubly optional: `.some(nil)` clears it, `nil` leaves it alone.
struct SidebarPatch {
    var name: String?
    var url: URL?
    var symbol: String?
    var badge: String??
    var hidden: Bool?

    mutating func merge(_ other: SidebarPatch) {
        if let value = other.name { name = value }
        if let value = other.url { url = value }
        if let value = other.symbol { symbol = value }
        if let value = other.badge { badge = value }
        if let value = other.hidden { hidden = value }
    }

    func apply(to item: inout SidebarItem) {
        if let name { item.name = name }
        if let url { item.url = url }
        if let symbol { item.symbol = symbol }
        if let badge { item.badge = badge }
        if let hidden { item.hidden = hidden }
    }
}

/// The apps rail and the assistants panel as one list each: items from config.json, plus whatever
/// extensions add, rename, hide or badge. UI code renders `items(_:)` and reacts to `changed`.
///
/// Extensions can add items of their own and change their own freely. Built-in items can be changed too,
/// but those changes are kept as per-extension overlays that disappear when the extension is turned off.
final class UIRegistry {
    static let shared = UIRegistry()
    static let changed = Notification.Name("SatelliteSidebarChanged")
    static let selectRequested = Notification.Name("SatelliteSidebarSelectRequested")

    static let maxItemsPerExtension = 8

    private struct Added {
        var item: SidebarItem
        var index: Int?
    }

    private var base: [SidebarSection: [SidebarItem]] = [:]
    private var added: [SidebarSection: [Added]] = [:]
    private var overlays: [SidebarSection: [String: [(owner: String, patch: SidebarPatch)]]] = [:]
    private var notifyScheduled = false

    // MARK: Reading

    func configure(_ config: AppConfig) {
        base[.apps] = config.apps.map(SidebarItem.init)
        base[.assistants] = config.assistants.map(SidebarItem.init)
        scheduleNotify()
    }

    /// Every item, hidden ones included, in display order with all overlays applied.
    func resolved(_ section: SidebarSection) -> [SidebarItem] {
        var list = base[section] ?? []
        for entry in added[section] ?? [] {
            list.insert(entry.item, at: Swift.min(entry.index ?? list.count, list.count))
        }
        for index in list.indices {
            for (_, patch) in overlays[section]?[list[index].id] ?? [] { patch.apply(to: &list[index]) }
        }
        return list
    }

    func items(_ section: SidebarSection) -> [SidebarItem] {
        resolved(section).filter { !$0.hidden }
    }

    /// What `satellite.ui.<section>.list()` returns to `caller`.
    func describe(_ section: SidebarSection, for caller: String) -> [[String: Any]] {
        let builtin = Set((base[section] ?? []).map(\.id))
        return resolved(section).map { item in
            let own = item.owner == caller
            return [
                "id": own ? String(item.id.dropFirst(caller.count + 1)) : item.id,
                "name": item.name,
                "url": item.url.absoluteString,
                "symbol": item.symbol,
                "badge": item.badge as Any? ?? NSNull(),
                "hidden": item.hidden,
                "builtin": builtin.contains(item.id),
                "owner": item.owner as Any? ?? NSNull(),
                "readOnly": item.owner != nil && !own,
            ]
        }
    }

    // MARK: Writing

    /// Adds an item owned by `owner`, or replaces the owner's existing item with the same local id.
    func add(_ section: SidebarSection, owner: String, input: [String: Any]) throws {
        guard let local = input["id"] as? String, Self.isValidLocalID(local) else {
            throw ManifestError("Item \u{201C}id\u{201D} must be 1\u{2013}40 letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} or \u{201C}_\u{201D}")
        }
        let patch = try Self.parsePatch(input, requireNameAndURL: true)
        let id = "\(owner)/\(local)"

        var list = added[section] ?? []
        let existing = list.firstIndex { $0.item.id == id }
        if existing == nil, list.filter({ $0.item.owner == owner }).count >= Self.maxItemsPerExtension {
            throw ManifestError("An extension can add at most \(Self.maxItemsPerExtension) items to the \(section.rawValue) list")
        }
        var item = SidebarItem(id: id, name: patch.name ?? local, url: patch.url!, symbol: patch.symbol ?? "globe", badge: nil, owner: owner)
        if let badge = patch.badge { item.badge = badge }
        item.hidden = patch.hidden ?? false

        var index: Int?
        if let raw = input["index"] {
            guard let number = raw as? NSNumber, number.intValue >= 0 else { throw ManifestError("\u{201C}index\u{201D} must be a non-negative number") }
            index = number.intValue
        }
        if let existing {
            list[existing].item = item
            if input["index"] != nil { list[existing].index = index }
        } else {
            list.append(Added(item: item, index: index))
        }
        added[section] = list
        scheduleNotify()
    }

    /// Changes an item the caller added, or layers a change over a built-in item.
    func update(_ section: SidebarSection, owner: String, id: String, input: [String: Any]) throws {
        let patch = try Self.parsePatch(input, requireNameAndURL: false)
        let own = "\(owner)/\(id)"

        if let position = added[section]?.firstIndex(where: { $0.item.id == own }) {
            patch.apply(to: &added[section]![position].item)
        } else if (base[section] ?? []).contains(where: { $0.id == id }) {
            var entries = overlays[section]?[id] ?? []
            if let i = entries.firstIndex(where: { $0.owner == owner }) {
                entries[i].patch.merge(patch)
            } else {
                entries.append((owner, patch))
            }
            overlays[section, default: [:]][id] = entries
        } else {
            throw Self.unknown(id, in: section)
        }
        scheduleNotify()
    }

    /// Deletes an item the caller added; for a built-in item this hides it until the extension is turned off.
    func remove(_ section: SidebarSection, owner: String, id: String) throws {
        let own = "\(owner)/\(id)"
        if let position = added[section]?.firstIndex(where: { $0.item.id == own }) {
            added[section]?.remove(at: position)
            overlays[section]?[own] = nil
            scheduleNotify()
        } else if (base[section] ?? []).contains(where: { $0.id == id }) {
            try update(section, owner: owner, id: id, input: ["hidden": true])
        }
        // Removing something that isn't there is fine, so "make sure it's gone" code needs no checks.
    }

    /// Resolves an id as the caller would write it and asks the window to show that item.
    func requestSelect(_ section: SidebarSection, owner: String, id: String) throws {
        let own = "\(owner)/\(id)"
        let all = resolved(section)
        guard let target = all.first(where: { $0.id == own }) ?? all.first(where: { $0.id == id }) else {
            throw Self.unknown(id, in: section)
        }
        guard !target.hidden else { throw ManifestError("Item \u{201C}\(id)\u{201D} is hidden") }
        NotificationCenter.default.post(
            name: Self.selectRequested, object: self, userInfo: ["section": section.rawValue, "id": target.id])
    }

    func removeAll(owner: String) {
        var touched = false
        for section in SidebarSection.allCases {
            let before = (added[section]?.count ?? 0, overlays[section]?.count ?? 0)
            added[section]?.removeAll { $0.item.owner == owner }
            for (itemID, entries) in overlays[section] ?? [:] {
                let kept = entries.filter { $0.owner != owner }
                overlays[section]?[itemID] = kept.isEmpty ? nil : kept
            }
            if before != (added[section]?.count ?? 0, overlays[section]?.count ?? 0) { touched = true }
        }
        if touched { scheduleNotify() }
    }

    /// Drops everything owned by extensions that are no longer running.
    func prune(keeping active: Set<String>) {
        var owners = Set<String>()
        for section in SidebarSection.allCases {
            (added[section] ?? []).compactMap(\.item.owner).forEach { owners.insert($0) }
            (overlays[section] ?? [:]).values.flatMap { $0 }.forEach { owners.insert($0.owner) }
        }
        for owner in owners.subtracting(active) { removeAll(owner: owner) }
    }

    // MARK: Validation

    static func isValidLocalID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, (1...40).contains(id.count) else { return false }
        let alnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return alnum.contains(first) && id.unicodeScalars.allSatisfy(alnum.union(CharacterSet(charactersIn: "._-")).contains)
    }

    private static func unknown(_ id: String, in section: SidebarSection) -> ManifestError {
        ManifestError("No item \u{201C}\(id)\u{201D} in the \(section.rawValue) list. Use list() to see the available ids.")
    }

    private static func parsePatch(_ input: [String: Any], requireNameAndURL: Bool) throws -> SidebarPatch {
        var patch = SidebarPatch()

        if let raw = input["name"] {
            guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...40).contains(text.count) else {
                throw ManifestError("\u{201C}name\u{201D} must be 1\u{2013}40 characters")
            }
            patch.name = text
        } else if requireNameAndURL {
            throw ManifestError("\u{201C}name\u{201D} is required")
        }

        if let raw = input["url"] {
            guard let text = raw as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw ManifestError("\u{201C}url\u{201D} must be an http(s) URL")
            }
            patch.url = url
        } else if requireNameAndURL {
            throw ManifestError("\u{201C}url\u{201D} is required")
        }

        if let raw = input["symbol"] {
            guard let text = raw as? String, (1...80).contains(text.count) else {
                throw ManifestError("\u{201C}symbol\u{201D} must be an SF Symbol name")
            }
            patch.symbol = text
        }

        if let raw = input["badge"] {
            if raw is NSNull {
                patch.badge = .some(nil)
            } else if let text = raw as? String ?? (raw as? NSNumber).map({ $0.stringValue }) {
                guard text.count <= 8 else { throw ManifestError("\u{201C}badge\u{201D} can be at most 8 characters") }
                patch.badge = .some(text.isEmpty ? nil : text)
            } else {
                throw ManifestError("\u{201C}badge\u{201D} must be text, a number or null")
            }
        }

        if let raw = input["hidden"] {
            guard let flag = raw as? Bool else { throw ManifestError("\u{201C}hidden\u{201D} must be true or false") }
            patch.hidden = flag
        }
        return patch
    }

    // MARK: Notification

    /// Several calls in one turn of the run loop produce one update.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [self] in
            notifyScheduled = false
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}
