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
        titleObserver = NotificationCenter.default.addObserver(forName: .webPaneStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let group = self?.selectedGroup, group.tabs.count > 1 else { return }
                self?.tabBar.updateTitles(group.tabs.map(\.tabTitle))
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
        if several { tabBar.show(titles: group.tabs.map(\.tabTitle), selected: group.selectedIndex) }
        view.window?.makeFirstResponder(current.webView)
    }
}

/// Right panel: a segmented switcher over lazily loaded assistant web views.
final class AssistantsViewController: NSViewController {
    private var panes: [String: WebPane] = [:]
    private var items: [SidebarItem] = []
    private(set) var selectedID: String?
    private let segmented = NSSegmentedControl()
    private let container = NSView()
    private var isLoaded = false

    var selectedPane: WebPane? { selectedID.flatMap { panes[$0] } }

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

    // Nothing is loaded until the panel is actually shown.
    override func viewDidAppear() {
        super.viewDidAppear()
        if !isLoaded {
            isLoaded = true
            if let selectedID { select(selectedID) }
        }
    }

    func setItems(_ newItems: [SidebarItem]) {
        let ids = Set(newItems.map(\.id))
        for id in panes.keys where !ids.contains(id) {
            panes.removeValue(forKey: id)?.teardown()
        }
        for item in newItems {
            if let pane = panes[item.id] {
                pane.update(name: item.name, url: item.url)
            } else {
                panes[item.id] = WebPane(name: item.name, url: item.url)
            }
        }
        items = newItems
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = newItems.first?.id }
        refreshSegments()
        if isLoaded, let selectedID { select(selectedID) }
    }

    func select(_ id: String) {
        guard items.contains(where: { $0.id == id }), let pane = panes[id] else { return }
        selectedID = id
        refreshSegments()
        guard isLoaded else { return }
        if pane.webView.superview == nil {
            container.addSubview(pane.webView)
            NSLayoutConstraint.activate([
                pane.webView.topAnchor.constraint(equalTo: container.topAnchor),
                pane.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        for (otherID, other) in panes where other.didCreateView { other.webView.isHidden = (otherID != id) }
        pane.loadIfNeeded()
        view.window?.makeFirstResponder(pane.webView)
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
