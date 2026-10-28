import Foundation

/// Satellite's tab groups: the saved ones (in config.json, through `AppsModel`) and which are loaded now.
///
/// Loading a group makes a tab for each of its pages and starts them loading in the background, without showing
/// them, so they're ready (and readable by the local MCP server) before anyone looks. Opening a group shows a
/// loaded group's tabs in the content area. Unloading closes its tabs; the saved group stays.
@MainActor
final class SatelliteGroups: ObservableObject {
    private let model: AppsModel
    @Published private(set) var loaded: [String: TabGroup] = [:]
    /// Bumped whenever a loaded group's tabs change, so views counting loaded pages refresh.
    @Published private(set) var revision = 0

    /// A group was loaded, or its tabs changed: the content area adds new tabs to its view (hidden unless shown).
    var onTabsChanged: ((String, TabGroup) -> Void)?
    /// A group was unloaded (or its last tab closed): the content area goes back to the list if it was shown.
    var onUnloaded: ((String) -> Void)?

    init(model: AppsModel = .shared) {
        self.model = model
    }

    var saved: [SavedGroup] { model.config.groups ?? [] }

    func group(_ id: String) -> SavedGroup? { saved.first { $0.id == id } }

    func group(named name: String) -> SavedGroup? {
        saved.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Saved groups

    /// A new group, saved and not loaded. Its name is made unique ("Research 2"), and it takes the first color no
    /// other group has.
    @discardableResult
    func create(name: String, color: GroupColor? = nil, members: [GroupMember]) -> SavedGroup {
        let used = Set(saved.map(\.color))
        let group = SavedGroup(name: uniqueName(name, excluding: nil),
                               color: color ?? GroupColor.allCases.first { !used.contains($0) } ?? .gray,
                               members: members)
        model.changeGroups { $0.append(group) }
        return group
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unique = uniqueName(trimmed, excluding: id)
        edit(id) { $0.name = unique }
    }

    func recolor(_ id: String, to color: GroupColor) {
        edit(id) { $0.color = color }
        bump(id)   // the chip and tab bands of a shown group change color too
    }

    /// Unloads the group and forgets it.
    func delete(_ id: String) {
        unload(id)
        model.changeGroups { $0.removeAll { $0.id == id } }
    }

    /// Adds a page to the group. If the group is loaded, it gets a tab, loading in the background.
    func add(_ member: GroupMember, to id: String) {
        edit(id) { $0.members.append(member) }
        if let tabs = loaded[id] { tabs.openMember(member).loadIfNeeded() }
    }

    /// Takes a page out of the group, closing its tab if it's loaded.
    func remove(memberID: String, from id: String) {
        edit(id) { $0.members.removeAll { $0.id == memberID } }
        if let tabs = loaded[id], let pane = tabs.tabs.first(where: { $0.groupMemberID == memberID }) {
            tabs.close(pane)
        }
    }

    /// Saves a tab a group's page opened (so it isn't one of the group's pages yet) as a page of that group.
    func keep(_ pane: WebPane, in id: String) {
        guard pane.groupMemberID == nil, let member = Self.member(from: pane) else { return }
        edit(id) { $0.members.append(member) }
        pane.groupMemberID = member.id
        bump(id)
    }

    /// A group page for whatever `pane` shows now.
    static func member(from pane: WebPane) -> GroupMember? {
        guard let url = pane.currentURL, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let title = pane.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupMember(name: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url)
    }

    static func member(from app: WebApp) -> GroupMember {
        GroupMember(name: app.name, url: app.url, appID: app.id)
    }

    // MARK: Loading

    func isLoaded(_ id: String) -> Bool { loaded[id] != nil }

    /// How many of the group's saved pages have a tab now.
    func loadedCount(_ id: String) -> Int {
        loaded[id]?.tabs.filter { $0.groupMemberID != nil }.count ?? 0
    }

    /// Loads the group in the background: a tab for each of its pages, all loading. A group that's already loaded
    /// gets tabs for any pages whose tab was closed. Returns nil for a group with no pages.
    @discardableResult
    func load(_ id: String) -> TabGroup? {
        guard let group = group(id), !group.members.isEmpty else { return loaded[id] }
        if let tabs = loaded[id] {
            let present = Set(tabs.tabs.compactMap(\.groupMemberID))
            for member in group.members where !present.contains(member.id) { tabs.openMember(member) }
            tabs.loadAll()
            return tabs
        }
        let tabs = TabGroup(group: group)
        tabs.onChange = { [weak self, weak tabs] in
            guard let self, let tabs else { return }
            self.revision += 1
            self.onTabsChanged?(id, tabs)
        }
        tabs.onEmpty = { [weak self] in self?.unload(id) }
        loaded[id] = tabs
        onTabsChanged?(id, tabs)
        tabs.loadAll()
        return tabs
    }

    func unload(_ id: String) {
        guard let tabs = loaded.removeValue(forKey: id) else { return }
        tabs.onChange = nil
        tabs.teardown()
        onUnloaded?(id)
    }

    // MARK: Helpers

    private func edit(_ id: String, _ change: (inout SavedGroup) -> Void) {
        model.changeGroups { groups in
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            change(&groups[index])
        }
    }

    private func bump(_ id: String) {
        revision += 1
        if let tabs = loaded[id] { onTabsChanged?(id, tabs) }
    }

    /// `name`, or "name 2", "name 3"… if another group already has it (ignoring case).
    private func uniqueName(_ name: String, excluding id: String?) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Group" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(saved.filter { $0.id != id }.map { $0.name.lowercased() })
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }
}
