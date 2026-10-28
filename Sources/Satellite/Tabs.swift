import AppKit
import WebKit

// MARK: - Tab groups (Chrome-style)

/// A fixed, named palette so a group's color survives config-free, in-memory identity and is easy to menu-pick.
enum TabClusterColor: String, CaseIterable {
    case gray, blue, red, orange, yellow, green, pink, purple

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var nsColor: NSColor {
        switch self {
        case .gray: return .systemGray
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .pink: return .systemPink
        case .purple: return .systemPurple
        }
    }
}

/// A named, colored group of tabs within one app's tab bar — like Chrome's tab groups. Members stay contiguous in
/// `TabGroup.tabs`: joining moves a tab next to the others, so the tab bar can draw one unbroken band per group.
/// Session-only, like the tabs themselves: Satellite doesn't restore tabs across launches, so there's nothing to
/// persist here either. `MCPBridge`'s `read_tab_group` tool looks a group up by `name` to snapshot every page in it.
struct TabCluster: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var color: TabClusterColor
    var collapsed = false
}

/// The tabs of one sidebar app. The first tab is the app itself and stays; the others are opened by links and
/// `window.open` and can be closed. Any tab but the first can also join a `TabCluster`.
@MainActor
final class TabGroup {
    private(set) var tabs: [WebPane]
    private(set) var selectedIndex = 0
    /// Also open links to other sites as tabs, instead of sending them to the default browser.
    var opensAllLinksInTabs: Bool
    /// Called whenever the tabs, the selected tab, or a cluster changes.
    var onChange: (() -> Void)?

    private(set) var clusters: [TabCluster] = []
    private var clusterOfTab: [ObjectIdentifier: UUID] = [:]

    var home: WebPane { tabs[0] }
    var current: WebPane { tabs[min(selectedIndex, tabs.count - 1)] }
    var hasClosableTab: Bool { selectedIndex > 0 }

    init(name: String, url: URL, opensAllLinksInTabs: Bool) {
        let home = WebPane(name: name, url: url)
        tabs = [home]
        self.opensAllLinksInTabs = opensAllLinksInTabs
        home.tabHost = self
    }

    /// A new tab for a page that asked for a new window. WebKit loads the request into the returned pane's view.
    func openTab(configuration: WKWebViewConfiguration) -> WebPane {
        let pane = WebPane(name: "New tab", url: nil, configuration: configuration)
        pane.tabHost = self
        pane.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane)
        }
        tabs.append(pane)
        selectedIndex = tabs.count - 1
        onChange?()
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        // A tab reached directly (e.g. Next Tab) shouldn't stay hidden behind its own collapsed group.
        if let id = clusterOfTab[ObjectIdentifier(tabs[index])], let i = clusters.firstIndex(where: { $0.id == id }) {
            clusters[i].collapsed = false
        }
        onChange?()
    }

    func selectNext() { if tabs.count > 1 { select((selectedIndex + 1) % tabs.count) } }
    func selectPrevious() { if tabs.count > 1 { select((selectedIndex - 1 + tabs.count) % tabs.count) } }

    /// Closes the selected tab unless it is the app's own. Returns whether a tab was closed.
    @discardableResult
    func closeCurrent() -> Bool {
        guard hasClosableTab else { return false }
        close(tabs[selectedIndex])
        return true
    }

    func close(at index: Int) {
        guard index > 0, tabs.indices.contains(index) else { return }
        close(tabs[index])
    }

    func close(_ pane: WebPane) {
        guard let index = tabs.firstIndex(where: { $0 === pane }), index > 0 else { return }
        tabs.remove(at: index)
        dropFromCluster(pane)
        pane.teardown()
        if selectedIndex >= index { selectedIndex = max(0, selectedIndex - 1) }
        onChange?()
    }

    /// Shows the app's own tab and takes it back to the address it started at.
    func goHome() {
        select(0)
        home.goHome()
    }

    func reloadAll() { tabs.forEach { $0.reloadIfLoaded() } }

    func teardown() {
        tabs.forEach { $0.teardown() }
    }

    // MARK: Clusters

    func cluster(for pane: WebPane) -> TabCluster? {
        guard let id = clusterOfTab[ObjectIdentifier(pane)] else { return nil }
        return clusters.first { $0.id == id }
    }

    func cluster(at index: Int) -> TabCluster? {
        tabs.indices.contains(index) ? cluster(for: tabs[index]) : nil
    }

    /// Case-insensitive, for the MCP tool's `group` argument.
    func cluster(named name: String) -> TabCluster? {
        clusters.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Members in tab order (they're always contiguous, but this doesn't rely on that).
    func panes(in cluster: TabCluster) -> [WebPane] {
        tabs.filter { clusterOfTab[ObjectIdentifier($0)] == cluster.id }
    }

    /// Puts the tab at `index` into a new cluster of its own. The home tab (index 0) can't be grouped.
    @discardableResult
    func newCluster(at index: Int, name: String, color: TabClusterColor) -> TabCluster? {
        guard index > 0, tabs.indices.contains(index) else { return nil }
        dropFromCluster(tabs[index])
        let cluster = TabCluster(name: name, color: color)
        clusters.append(cluster)
        clusterOfTab[ObjectIdentifier(tabs[index])] = cluster.id
        onChange?()
        return cluster
    }

    /// Moves the tab at `index` next to `cluster`'s other members, then joins it.
    func join(_ index: Int, to cluster: TabCluster) {
        guard index > 0, tabs.indices.contains(index), clusters.contains(where: { $0.id == cluster.id }) else { return }
        let pane = tabs[index]
        let selectedPane = tabs[selectedIndex]
        dropFromCluster(pane)
        tabs.remove(at: tabs.firstIndex { $0 === pane }!)
        let insertAt = (tabs.lastIndex { clusterOfTab[ObjectIdentifier($0)] == cluster.id }).map { $0 + 1 } ?? tabs.count
        tabs.insert(pane, at: insertAt)
        clusterOfTab[ObjectIdentifier(pane)] = cluster.id
        selectedIndex = tabs.firstIndex { $0 === selectedPane } ?? 0
        onChange?()
    }

    /// Removes the tab at `index` from its cluster, if any. The cluster itself goes away once it's empty.
    func leaveCluster(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        dropFromCluster(tabs[index])
        onChange?()
    }

    func rename(_ cluster: TabCluster, to name: String) {
        guard let i = clusters.firstIndex(where: { $0.id == cluster.id }), !name.isEmpty else { return }
        clusters[i].name = name
        onChange?()
    }

    func recolor(_ cluster: TabCluster, to color: TabClusterColor) {
        guard let i = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[i].color = color
        onChange?()
    }

    func toggleCollapsed(_ cluster: TabCluster) {
        guard let i = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[i].collapsed.toggle()
        onChange?()
    }

    /// Keeps every member tab open, just not grouped.
    func ungroup(_ cluster: TabCluster) {
        for pane in panes(in: cluster) { clusterOfTab.removeValue(forKey: ObjectIdentifier(pane)) }
        clusters.removeAll { $0.id == cluster.id }
        onChange?()
    }

    /// Closes every tab in `cluster`.
    func closeCluster(_ cluster: TabCluster) {
        for pane in panes(in: cluster) { close(pane) }
    }

    /// A default name that doesn't collide with an existing group ("Group 2", "Group 3", ...).
    func nextClusterName() -> String {
        var n = clusters.count + 1
        while clusters.contains(where: { $0.name == "Group \(n)" }) { n += 1 }
        return "Group \(n)"
    }

    private func dropFromCluster(_ pane: WebPane) {
        guard let id = clusterOfTab.removeValue(forKey: ObjectIdentifier(pane)) else { return }
        if !tabs.contains(where: { clusterOfTab[ObjectIdentifier($0)] == id }) {
            clusters.removeAll { $0.id == id }
        }
    }

    /// What the tab bar draws, in order: a chip before each cluster's first member, then its tabs — skipped while
    /// the cluster is collapsed, so only the chip (with a count) shows for it.
    enum BarEntry {
        case tab(index: Int)
        case chip(TabCluster, count: Int)
    }

    var barEntries: [BarEntry] {
        var out: [BarEntry] = []
        var shown = Set<UUID>()
        for (index, pane) in tabs.enumerated() {
            guard let id = clusterOfTab[ObjectIdentifier(pane)], let cluster = clusters.first(where: { $0.id == id }) else {
                out.append(.tab(index: index)); continue
            }
            if !shown.contains(id) {
                shown.insert(id)
                out.append(.chip(cluster, count: panes(in: cluster).count))
            }
            if !cluster.collapsed { out.append(.tab(index: index)) }
        }
        return out
    }
}

// MARK: - Tab bar

/// One tab: a title and (for closable tabs) a close button. A grouped tab shows a thin band of its cluster's color.
final class TabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// The right-click menu, made when it opens so it describes the page the tab shows now.
    var makeMenu: (() -> NSMenu?)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let accent = CALayer()

    var isSelected = false {
        didSet { refreshAppearance() }
    }

    init(title: String, selected: Bool, closable: Bool, clusterColor: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)

        if let clusterColor {
            accent.backgroundColor = clusterColor.cgColor
            accent.cornerRadius = 1.5
            layer?.addSublayer(accent)
        }

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = !closable
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: closable ? closeButton.leadingAnchor : trailingAnchor, constant: closable ? -4 : -10),
        ])
        isSelected = selected
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setTitle(_ title: String) { label.stringValue = title }

    override func layout() {
        super.layout()
        accent.frame = CGRect(x: 5, y: 1, width: max(0, bounds.width - 10), height: 3)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return !closeButton.isHidden && closeButton.frame.contains(convert(point, from: superview)) ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?() ?? super.menu(for: event)
    }

    @objc private func closeClicked() { onClose?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        }
    }
}

/// The small colored pill before a cluster's tabs: its name, and a count while collapsed. Click toggles collapse;
/// right-click opens the group's menu (rename, recolor, collapse, ungroup, close).
final class TabClusterChipView: NSView {
    var onClick: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    private let color: NSColor
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(cluster: TabCluster) {
        color = cluster.color.nsColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.stringValue = cluster.name
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyBackground()
    }

    /// `count` only shows while collapsed, matching Chrome (an expanded group's tabs are already visible, so
    /// counting them again would be noise).
    convenience init(cluster: TabCluster, count: Int) {
        self.init(cluster: cluster)
        if cluster.collapsed { label.stringValue = "\(cluster.name) (\(count))" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() ?? super.menu(for: event) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor }
    }
}

/// A strip of tabs above the web content; only visible when an app has more than one. Grouped tabs show a colored
/// chip (`TabClusterChipView`) before them.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The right-click menu of the tab at an index.
    var menuForTab: ((Int) -> NSMenu?)?
    /// The right-click menu of a cluster's chip.
    var menuForChip: ((TabCluster) -> NSMenu?)?
    var onChipClick: ((TabCluster) -> Void)?

    private let stack = NSStackView()
    private var buttons: [TabButton] = []
    private var chips: [TabClusterChipView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill   // mixed-width chips and tabs; .fillEqually would stretch chips to tab width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Rebuilds the bar from `group`'s current tabs and clusters. Cheap enough to call on every title change too.
    func show(_ group: TabGroup) {
        (buttons as [NSView] + chips).forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons = []
        chips = []
        for entry in group.barEntries {
            switch entry {
            case .chip(let cluster, let count):
                let chip = TabClusterChipView(cluster: cluster, count: count)
                chip.onClick = { [weak self] in self?.onChipClick?(cluster) }
                chip.makeMenu = { [weak self] in self?.menuForChip?(cluster) }
                chips.append(chip)
                stack.addArrangedSubview(chip)
            case .tab(let index):
                let button = TabButton(title: group.tabs[index].tabTitle, selected: index == group.selectedIndex,
                                        closable: index > 0, clusterColor: group.cluster(at: index)?.color.nsColor)
                button.onSelect = { [weak self] in self?.onSelect?(index) }
                button.onClose = { [weak self] in self?.onClose?(index) }
                button.makeMenu = { [weak self] in self?.menuForTab?(index) }
                buttons.append(button)
                stack.addArrangedSubview(button)
            }
        }
    }
}
