import AppKit
import WebKit

/// Center area: one lazily loaded web view per app, only the selected one visible.
final class ContentViewController: NSViewController {
    private var panes: [String: WebPane] = [:]
    private(set) var selectedID: String?

    var selectedPane: WebPane? { selectedID.flatMap { panes[$0] } }

    override func loadView() {
        view = NSView()
    }

    /// Follows the sidebar: creates panes for new items, drops panes of removed ones, and applies renames
    /// and address changes. If the selected item disappeared nothing is selected until `select` is called.
    func setItems(_ items: [SidebarItem]) {
        let ids = Set(items.map(\.id))
        for id in panes.keys where !ids.contains(id) {
            panes.removeValue(forKey: id)?.teardown()
        }
        for item in items {
            if let pane = panes[item.id] {
                pane.update(name: item.name, url: item.url)
            } else {
                panes[item.id] = WebPane(name: item.name, url: item.url)
            }
        }
        if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
    }

    func select(_ id: String) {
        guard let pane = panes[id] else { return }
        selectedID = id
        if pane.webView.superview == nil {
            view.addSubview(pane.webView)
            NSLayoutConstraint.activate([
                pane.webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                pane.webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pane.webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pane.webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        for (otherID, other) in panes where other.didCreateView { other.webView.isHidden = (otherID != id) }
        pane.loadIfNeeded()
        view.window?.makeFirstResponder(pane.webView)
    }

    func reloadAll() {
        panes.values.forEach { $0.reloadIfLoaded() }
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
