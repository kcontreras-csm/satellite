import AppKit
import WebKit

/// Center area: one lazily loaded group of tabs per app, only the selected app's current tab visible.
final class ContentViewController: NSViewController {
    private var groups: [String: TabGroup] = [:]
    private(set) var selectedID: String?
    private let tabBar = TabBarView()
    private let container = NSView()
    private var tabBarHeight: NSLayoutConstraint?
    private var titleObserver: NSObjectProtocol?

    var selectedGroup: TabGroup? { selectedID.flatMap { groups[$0] } }
    /// Where the tab and app menus copy links to.
    var linkPasteboard: NSPasteboard = .general
    /// The page in front: the selected app's current tab.
    var selectedPane: WebPane? { selectedGroup?.current }
    var hasClosableTab: Bool { selectedGroup?.hasClosableTab ?? false }

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
        tabBar.onChipClick = { [weak self] in self?.selectedGroup?.toggleCollapsed($0) }
        tabBar.menuForChip = { [weak self] in self?.chipMenu(for: $0) }
        titleObserver = NotificationCenter.default.addObserver(forName: .webPaneStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let group = self.selectedGroup, group.tabs.count > 1 else { return }
                self.tabBar.show(group)
            }
        }
        view = root
    }

    /// Follows the sidebar: creates tab groups for new items, drops groups of removed ones, and applies renames
    /// and address changes. If the selected item disappeared nothing is selected until `select` is called.
    func setItems(_ items: [SidebarItem]) {
        let ids = Set(items.map(\.id))
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
        if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
    }

    func select(_ id: String) {
        guard let group = groups[id] else { return }
        selectedID = id
        show(group)
    }

    /// Right-click on a tab: its link, Close Tab for the ones that can close, then its group.
    private func tabMenu(at index: Int) -> NSMenu? {
        guard let group = selectedGroup, group.tabs.indices.contains(index) else { return nil }
        var extra: [NSMenuItem] = []
        if index > 0 {
            extra.append(ClosureMenuItem(title: "Close Tab") { [weak group] in group?.close(at: index) })
        }
        if index > 0 {
            extra.append(.separator())
            if let cluster = group.cluster(at: index) {
                extra.append(ClosureMenuItem(title: "Remove from \u{201C}\(cluster.name)\u{201D}") { [weak group] in group?.leaveCluster(at: index) })
            } else {
                let item = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
                item.submenu = addToGroupMenu(for: index, in: group)
                extra.append(item)
            }
        }
        return PageLink.menu(for: group.tabs[index], window: view.window, extra: extra, pasteboard: linkPasteboard)
    }

    private func addToGroupMenu(for index: Int, in group: TabGroup) -> NSMenu {
        let menu = NSMenu()
        for cluster in group.clusters {
            let item = ClosureMenuItem(title: cluster.name) { [weak group] in group?.join(index, to: cluster) }
            item.image = Self.swatch(cluster.color)
            menu.addItem(item)
        }
        if !group.clusters.isEmpty { menu.addItem(.separator()) }
        let newGroup = NSMenuItem(title: "New Group", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in TabClusterColor.allCases {
            let item = ClosureMenuItem(title: color.label) { [weak group] in
                guard let group else { return }
                group.newCluster(at: index, name: group.nextClusterName(), color: color)
            }
            item.image = Self.swatch(color)
            colors.addItem(item)
        }
        newGroup.submenu = colors
        menu.addItem(newGroup)
        return menu
    }

    /// Right-click (or click, to toggle collapse) on a group's chip.
    private func chipMenu(for cluster: TabCluster) -> NSMenu? {
        guard let group = selectedGroup, group.clusters.contains(where: { $0.id == cluster.id }) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: cluster.collapsed ? "Expand Group" : "Collapse Group") { [weak group] in group?.toggleCollapsed(cluster) })
        menu.addItem(ClosureMenuItem(title: "Rename Group\u{2026}") { [weak self, weak group] in
            guard let self, let group, let name = self.promptForGroupName(current: cluster.name) else { return }
            group.rename(cluster, to: name)
        })
        let recolor = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in TabClusterColor.allCases {
            let item = ClosureMenuItem(title: color.label) { [weak group] in group?.recolor(cluster, to: color) }
            item.image = Self.swatch(color)
            item.state = color == cluster.color ? .on : .off
            colors.addItem(item)
        }
        recolor.submenu = colors
        menu.addItem(recolor)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Ungroup Tabs") { [weak group] in group?.ungroup(cluster) })
        menu.addItem(ClosureMenuItem(title: "Close Group") { [weak group] in group?.closeCluster(cluster) })
        return menu
    }

    private func promptForGroupName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A small colored dot for a color's menu items (group picking and recoloring).
    private static func swatch(_ color: TabClusterColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Right-click on an app in the rail: the link of the tab it shows (its own page, or another tab it opened).
    func appMenu(for id: String) -> NSMenu? {
        guard let group = groups[id] else { return nil }
        return PageLink.menu(for: group.current, window: view.window, pasteboard: linkPasteboard)
    }

    func nextTab() { selectedGroup?.selectNext() }
    func previousTab() { selectedGroup?.selectPrevious() }
    @discardableResult func closeCurrentTab() -> Bool { selectedGroup?.closeCurrent() ?? false }

    func reloadAll() {
        groups.values.forEach { $0.reloadAll() }
    }

    /// Makes the group's current tab the only visible web view and shows the tab bar when there are several.
    private func show(_ group: TabGroup) {
        let current = group.current
        for other in groups.values {
            for tab in other.tabs where tab.didCreateView && tab !== current { tab.webView.isHidden = true }
        }
        if current.webView.superview == nil {
            container.addSubview(current.webView)
            NSLayoutConstraint.activate([
                current.webView.topAnchor.constraint(equalTo: container.topAnchor),
                current.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                current.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                current.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        current.webView.isHidden = false
        current.loadIfNeeded()

        let several = group.tabs.count > 1
        tabBar.isHidden = !several
        tabBarHeight?.constant = several ? 34 : 0
        if several { tabBar.show(group) }
        view.window?.makeFirstResponder(current.webView)
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
