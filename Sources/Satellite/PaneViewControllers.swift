import AppKit
import WebKit

/// One page open in Satellite — an app's tab, a tab group's tab, or a web assistant — for the local MCP server.
struct OpenPage {
    enum Kind { case app, group, assistant }

    let pane: WebPane
    let kind: Kind
    /// The app's, group's or assistant's name and id.
    let owner: String
    let ownerID: String
    /// The tab its app or group shows (an assistant has only the one).
    let isCurrentTab: Bool
    /// Whether it has ever loaded. An app that was never opened has no page yet, and listing or reading it
    /// mustn't load it (that could start a sign-in).
    var isLoaded: Bool { pane.didCreateView && pane.webView.url != nil }
}

/// Center area: an app's tabs (one lazily loaded set per app), the list of tab groups, or a tab group's tabs.
/// Only the current tab of what's selected is visible; every other loaded tab keeps running, hidden.
final class ContentViewController: NSViewController {
    enum Selection: Equatable {
        case app(String)
        case groupsList
        case group(String)
    }

    private var groups: [String: TabGroup] = [:]
    /// The apps' ids in rail order.
    private var order: [String] = []
    private(set) var selection: Selection?
    let satelliteGroups = SatelliteGroups()
    private let tabBar = TabBarView()
    private let container = NSView()
    private var groupsList: NSView?
    private var tabBarHeight: NSLayoutConstraint?
    private var titleObserver: NSObjectProtocol?

    /// What's shown changed without MainWindowController asking (a shown group was unloaded or closed its last
    /// tab, or its chip was clicked), so the rail, the title and the address bar can follow.
    var onSelectionChange: (() -> Void)?

    /// The selected app's id; nil while the groups list or a group is shown.
    var selectedID: String? { if case .app(let id) = selection { return id } else { return nil } }
    var shownGroupID: String? { if case .group(let id) = selection { return id } else { return nil } }
    var selectedGroup: TabGroup? {
        switch selection {
        case .app(let id): return groups[id]
        case .group(let id): return satelliteGroups.loaded[id]
        case .groupsList, nil: return nil
        }
    }
    /// Where the tab and app menus copy links to.
    var linkPasteboard: NSPasteboard = .general
    /// The page in front: the current tab of the selected app or group; nil on the groups list.
    var selectedPane: WebPane? { selectedGroup?.current }
    var hasClosableTab: Bool { selectedGroup?.hasClosableTab ?? false }

    /// Every app's and every loaded group's tabs, for hiding all but the one shown.
    private var allTabs: [TabGroup] { Array(groups.values) + Array(satelliteGroups.loaded.values) }

    /// Every tab of every app (rail order), then of every loaded tab group (in the order they're listed).
    /// Background tabs keep running and can be read the same as the one in front.
    var openPages: [OpenPage] {
        var pages: [OpenPage] = []
        for id in order {
            guard let group = groups[id] else { continue }
            for (index, pane) in group.tabs.enumerated() {
                pages.append(OpenPage(pane: pane, kind: .app, owner: group.home.name, ownerID: id, isCurrentTab: index == group.selectedIndex))
            }
        }
        for saved in satelliteGroups.saved {
            guard let tabs = satelliteGroups.loaded[saved.id] else { continue }
            for (index, pane) in tabs.tabs.enumerated() {
                pages.append(OpenPage(pane: pane, kind: .group, owner: saved.name, ownerID: saved.id, isCurrentTab: index == tabs.selectedIndex))
            }
        }
        return pages
    }

    deinit {
        if let titleObserver { NotificationCenter.default.removeObserver(titleObserver) }
    }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.isHidden = true
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        root.addSubview(tabBar)

        let height = tabBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeight = height
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            height,
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        tabBar.onSelect = { [weak self] in self?.selectedGroup?.select($0) }
        tabBar.onClose = { [weak self] in self?.selectedGroup?.close(at: $0) }
        tabBar.menuForTab = { [weak self] in self?.tabMenu(at: $0) }
        tabBar.onChipClick = { [weak self] in
            self?.showGroupsList()
            self?.onSelectionChange?()
        }
        titleObserver = NotificationCenter.default.addObserver(forName: .webPaneStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let group = self.selectedGroup else { return }
                self.refreshTabBar(group)
            }
        }

        satelliteGroups.onTabsChanged = { [weak self] id, tabs in
            guard let self else { return }
            if self.shownGroupID == id { self.show(tabs) } else { self.attachHidden(tabs) }
        }
        satelliteGroups.onUnloaded = { [weak self] id in
            guard let self, self.shownGroupID == id else { return }
            self.showGroupsList()
            self.onSelectionChange?()
        }
        view = root
    }

    /// The list of tab groups (a SwiftUI view), shown in place of the pages when Groups is selected in the rail.
    func setGroupsList(_ list: NSView) {
        groupsList?.removeFromSuperview()
        list.translatesAutoresizingMaskIntoConstraints = false
        list.isHidden = selection != .groupsList
        container.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: container.topAnchor),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        groupsList = list
    }

    /// Follows the sidebar: creates tab sets for new apps, drops those of removed ones, and applies renames and
    /// address changes. If the selected app disappeared nothing is selected until `select` is called.
    func setItems(_ items: [SidebarItem]) {
        let ids = Set(items.map(\.id))
        order = items.map(\.id)
        for id in groups.keys where !ids.contains(id) {
            groups.removeValue(forKey: id)?.teardown()
        }
        for item in items {
            if let group = groups[item.id] {
                group.home.update(name: item.name, url: item.url)
                group.opensAllLinksInTabs = item.opensLinksInTabs
            } else {
                let group = TabGroup(name: item.name, url: item.url, opensAllLinksInTabs: item.opensLinksInTabs)
                group.onChange = { [weak self, weak group] in
                    guard let self, let group, self.selectedGroup === group else { return }
                    self.show(group)
                }
                groups[item.id] = group
            }
        }
        if let selectedID, !ids.contains(selectedID) { selection = nil }
    }

    func select(_ id: String) {
        guard let group = groups[id] else { return }
        selection = .app(id)
        show(group)
    }

    /// Shows the list of tab groups instead of any page.
    func showGroupsList() {
        selection = .groupsList
        for set in allTabs {
            for tab in set.tabs where tab.didCreateView { tab.webView.isHidden = true }
        }
        tabBar.isHidden = true
        tabBarHeight?.constant = 0
        groupsList?.isHidden = false
        view.window?.makeFirstResponder(groupsList)
        NotificationCenter.default.post(name: .webPaneStateChanged, object: nil)
    }

    /// Shows a tab group's tabs, loading it first if it isn't. Returns whether it could (a group needs a page).
    @discardableResult
    func openGroup(_ id: String) -> Bool {
        guard let tabs = satelliteGroups.load(id) else { return false }
        selection = .group(id)
        show(tabs)
        return true
    }

    /// Right-click on a tab: its link, Close Tab for the ones that can close, then its group items.
    private func tabMenu(at index: Int) -> NSMenu? {
        guard let group = selectedGroup, group.tabs.indices.contains(index) else { return nil }
        let pane = group.tabs[index]
        var extra: [NSMenuItem] = []
        if group.canClose(index) {
            extra.append(ClosureMenuItem(title: "Close Tab") { [weak group] in group?.close(at: index) })
            extra.append(.separator())
        }
        extra += groupMenuItems(for: pane)
        return PageLink.menu(for: pane, window: view.window, extra: extra, pasteboard: linkPasteboard)
    }

    /// The menu of a page as a whole — an app in the rail, or the address bar: its link, then its group items.
    func pageMenu(for pane: WebPane) -> NSMenu {
        PageLink.menu(for: pane, window: view.window, extra: groupMenuItems(for: pane), pasteboard: linkPasteboard)
    }

    /// For one of a group's tabs: take it out of the group (or keep a tab the group's pages opened). For any other
    /// page: Add to Group.
    func groupMenuItems(for pane: WebPane) -> [NSMenuItem] {
        guard let groupID = pane.tabHost?.savedGroupID, let saved = satelliteGroups.group(groupID) else {
            let item = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
            item.submenu = addToGroupMenu(for: pane)
            return [item]
        }
        if let memberID = pane.groupMemberID {
            return [ClosureMenuItem(title: "Remove from \u{201C}\(saved.name)\u{201D}") { [weak self] in
                self?.satelliteGroups.remove(memberID: memberID, from: groupID)
            }]
        }
        // A tab one of the group's pages opened: here for now, kept only if asked.
        return [ClosureMenuItem(title: "Keep in \u{201C}\(saved.name)\u{201D}") { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.satelliteGroups.keep(pane, in: groupID)
        }]
    }

    /// The groups an app's tab can be added to, and a new one. Adding copies the page's address into the group;
    /// the tab itself stays in its app.
    private func addToGroupMenu(for pane: WebPane) -> NSMenu {
        let menu = NSMenu()
        for saved in satelliteGroups.saved {
            let item = ClosureMenuItem(title: saved.name) { [weak self, weak pane] in
                guard let self, let pane, let member = SatelliteGroups.member(from: pane) else { return }
                self.satelliteGroups.add(member, to: saved.id)
                Toast.show("Added to \u{201C}\(saved.name)\u{201D}", in: self.view.window)
            }
            item.image = Self.swatch(saved.color)
            menu.addItem(item)
        }
        if !satelliteGroups.saved.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "New Group") { [weak self, weak pane] in
            guard let self, let pane, let member = SatelliteGroups.member(from: pane) else { return }
            let saved = self.satelliteGroups.create(name: member.name, members: [member])
            Toast.show("Added to a new group, \u{201C}\(saved.name)\u{201D}", in: self.view.window)
        })
        return menu
    }

    /// A small colored dot for a group's menu items.
    static func swatch(_ color: GroupColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Right-click on an app in the rail: the tab it shows (its own page, or another tab it opened).
    func appMenu(for id: String) -> NSMenu? {
        guard let group = groups[id] else { return nil }
        return pageMenu(for: group.current)
    }

    func nextTab() { selectedGroup?.selectNext() }
    func previousTab() { selectedGroup?.selectPrevious() }
    @discardableResult func closeCurrentTab() -> Bool { selectedGroup?.closeCurrent() ?? false }

    func reloadAll() {
        allTabs.forEach { $0.reloadAll() }
    }

    /// Puts a loaded group's tabs into the view, hidden, so they load and run as the other background tabs do.
    private func attachHidden(_ set: TabGroup) {
        for tab in set.tabs where tab.webView.superview == nil {
            attach(tab.webView)
            tab.webView.isHidden = true
        }
    }

    private func attach(_ webView: WKWebView) {
        container.addSubview(webView, positioned: .below, relativeTo: groupsList)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// An app's tab bar shows once it has several tabs; a group's always shows, with its chip.
    private func refreshTabBar(_ set: TabGroup) {
        let chip = set.savedGroupID.flatMap { satelliteGroups.group($0) }.map { (name: $0.name, color: $0.color) }
        let shows = chip != nil || set.tabs.count > 1
        tabBar.isHidden = !shows
        tabBarHeight?.constant = shows ? 34 : 0
        if shows { tabBar.show(set, chip: chip) }
    }

    /// Makes the set's current tab the only visible web view, and shows its tab bar.
    private func show(_ set: TabGroup) {
        let current = set.current
        for other in allTabs {
            for tab in other.tabs where tab.didCreateView && tab !== current { tab.webView.isHidden = true }
        }
        groupsList?.isHidden = true
        if current.webView.superview == nil { attach(current.webView) }
        current.webView.isHidden = false
        current.loadIfNeeded()
        refreshTabBar(set)
        view.window?.makeFirstResponder(current.webView)
        // The front tab or app changed: let the toolbar (back/forward state, the address bar) catch up.
        NotificationCenter.default.post(name: .webPaneStateChanged, object: current)
    }
}

/// Right panel: a segmented switcher over the assistants, each a web view or a terminal, all loaded up front.
final class AssistantsViewController: NSViewController {
    private var panes: [String: WebPane] = [:]
    private var terminals: [String: TerminalPane] = [:]
    private var items: [SidebarItem] = []
    private(set) var selectedID: String?
    private let segmented = NSSegmentedControl()
    private let container = NSView()
    private var isLoaded = false

    /// The selected assistant when it is a web page; nil when it is a terminal.
    var selectedPane: WebPane? { selectedID.flatMap { panes[$0] } }
    /// The selected assistant when it is a terminal.
    var selectedTerminal: TerminalPane? { selectedID.flatMap { terminals[$0] } }
    /// The first terminal in the panel's order, if there is one.
    var firstTerminalID: String? { items.first { terminals[$0.id] != nil }?.id }

    /// The web assistants, in panel order. Terminals aren't pages, so they aren't here.
    var openPages: [OpenPage] {
        items.compactMap { item in
            panes[item.id].map { OpenPage(pane: $0, kind: .assistant, owner: item.name, ownerID: item.id, isCurrentTab: true) }
        }
    }

    override func loadView() {
        let root = NSView()
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.segmentDistribution = .fillEqually
        segmented.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(segmented)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refreshSegments()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let selectedID { select(selectedID) }   // focus the shown assistant; all of them are already preloaded
    }

    func setItems(_ newItems: [SidebarItem]) {
        let ids = Set(newItems.map(\.id))
        let terminalIDs = Set(newItems.filter { $0.terminal != nil }.map(\.id))
        for id in panes.keys where !ids.contains(id) || terminalIDs.contains(id) {
            panes.removeValue(forKey: id)?.teardown()
        }
        for id in terminals.keys where !terminalIDs.contains(id) {
            terminals.removeValue(forKey: id)?.teardown()
        }
        for item in newItems {
            if let config = item.terminal {
                if let terminal = terminals[item.id] {
                    terminal.update(name: item.name, config: config)
                } else {
                    terminals[item.id] = TerminalPane(id: item.id, name: item.name, config: config)
                }
            } else if let pane = panes[item.id] {
                pane.update(name: item.name, url: item.url)
            } else {
                let pane = WebPane(name: item.name, url: item.url)
                pane.isAssistant = true
                panes[item.id] = pane
            }
        }
        items = newItems
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = newItems.first?.id }
        refreshSegments()
        preloadAll()
        if let selectedID { select(selectedID) }
    }

    private func attach(_ content: NSView) {
        guard content.superview == nil else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Loads every assistant up front — so each is signed in and ready, and its content scripts run immediately
    /// (e.g. the Slackbot panel's), not just the one in view. Terminals start their shell. Only the selected assistant
    /// is shown; the rest load behind it.
    func preloadAll() {
        isLoaded = true
        for (id, pane) in panes {
            attach(pane.webView)
            pane.loadIfNeeded()
            pane.webView.isHidden = (id != selectedID)
        }
        for (id, terminal) in terminals {
            attach(terminal.host)
            terminal.startIfNeeded()
            terminal.host.isHidden = (id != selectedID)
        }
    }

    func select(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
        refreshSegments()
        for (otherID, other) in panes where other.didCreateView { other.webView.isHidden = (otherID != id) }
        for (otherID, other) in terminals { other.host.isHidden = (otherID != id) }
        if let pane = panes[id] {
            attach(pane.webView)
            pane.loadIfNeeded()
            view.window?.makeFirstResponder(pane.webView)
        } else if let terminal = terminals[id] {
            attach(terminal.host)
            terminal.startIfNeeded()
            view.window?.makeFirstResponder(terminal.view)
        }
    }

    func reloadAll() {
        panes.values.forEach { $0.reloadIfLoaded() }
    }

    private func refreshSegments() {
        segmented.segmentCount = items.count
        for (index, item) in items.enumerated() {
            segmented.setLabel(item.badge.map { "\(item.name) (\($0))" } ?? item.name, forSegment: index)
            segmented.setToolTip(item.owner.map { "Added by the \($0) extension" }, forSegment: index)
        }
        segmented.selectedSegment = items.firstIndex { $0.id == selectedID } ?? -1
        segmented.isHidden = items.isEmpty
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard items.indices.contains(sender.selectedSegment) else { return }
        select(items[sender.selectedSegment].id)
    }
}
