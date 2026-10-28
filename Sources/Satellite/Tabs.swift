import AppKit
import WebKit

extension GroupColor {
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

/// The tabs shown together in the content area: one sidebar app's, or one Satellite tab group's (see
/// `SatelliteGroups`). An app's first tab is the app itself and stays; its other tabs are opened by links and
/// `window.open` and can be closed. A group's tabs are its pages, and any of them can be closed.
@MainActor
final class TabGroup {
    private(set) var tabs: [WebPane]
    private(set) var selectedIndex = 0
    /// Also open links to other sites as tabs, instead of sending them to the default browser.
    var opensAllLinksInTabs: Bool
    /// Called whenever the tabs or the selected tab change.
    var onChange: (() -> Void)?
    /// The saved group these are the tabs of; nil for an app.
    let savedGroupID: String?
    /// A group's last tab closed. It has nothing left to show, so the caller unloads it.
    var onEmpty: (() -> Void)?

    var isSatelliteGroup: Bool { savedGroupID != nil }
    var home: WebPane { tabs[0] }
    var current: WebPane { tabs[min(selectedIndex, tabs.count - 1)] }
    var hasClosableTab: Bool { canClose(selectedIndex) }

    func canClose(_ index: Int) -> Bool { tabs.indices.contains(index) && (isSatelliteGroup || index > 0) }

    init(name: String, url: URL, opensAllLinksInTabs: Bool) {
        let home = WebPane(name: name, url: url)
        tabs = [home]
        self.opensAllLinksInTabs = opensAllLinksInTabs
        savedGroupID = nil
        home.tabHost = self
    }

    /// The tabs of a saved group, one per page, none loaded yet.
    init(group: SavedGroup) {
        tabs = []
        opensAllLinksInTabs = false
        savedGroupID = group.id
        tabs = group.members.map(makeMemberTab)
    }

    /// A tab for a page added to this group while it's loaded, at the end. It doesn't take the selection.
    @discardableResult
    func openMember(_ member: GroupMember) -> WebPane {
        let pane = makeMemberTab(member)
        tabs.append(pane)
        onChange?()
        return pane
    }

    private func makeMemberTab(_ member: GroupMember) -> WebPane {
        let pane = WebPane(name: member.name, url: member.url)
        pane.groupMemberID = member.id
        adopt(pane)
        return pane
    }

    private func adopt(_ pane: WebPane) {
        pane.tabHost = self
        pane.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane)
        }
    }

    /// Starts loading every tab that hasn't loaded yet, in the background.
    func loadAll() { tabs.forEach { $0.loadIfNeeded() } }

    /// A new tab for a page that asked for a new window. WebKit loads the request into the returned pane's view.
    func openTab(configuration: WKWebViewConfiguration) -> WebPane {
        let pane = WebPane(name: "New tab", url: nil, configuration: configuration)
        adopt(pane)
        tabs.append(pane)
        selectedIndex = tabs.count - 1
        onChange?()
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onChange?()
    }

    func selectNext() { if tabs.count > 1 { select((selectedIndex + 1) % tabs.count) } }
    func selectPrevious() { if tabs.count > 1 { select((selectedIndex - 1 + tabs.count) % tabs.count) } }

    /// Closes the selected tab unless it is an app's own. Returns whether a tab was closed.
    @discardableResult
    func closeCurrent() -> Bool {
        guard hasClosableTab else { return false }
        close(tabs[selectedIndex])
        return true
    }

    func close(at index: Int) {
        guard canClose(index) else { return }
        close(tabs[index])
    }

    /// Closes a tab. In a group, the page stays in the saved group; it just isn't loaded until the group is again.
    func close(_ pane: WebPane) {
        guard let index = tabs.firstIndex(where: { $0 === pane }), canClose(index) else { return }
        tabs.remove(at: index)
        pane.teardown()
        if tabs.isEmpty {
            onEmpty?()
            return
        }
        if selectedIndex >= index { selectedIndex = max(0, selectedIndex - 1) }
        onChange?()
    }

    /// An app shows its own tab and takes it back to the address it started at; a group's tab goes back to the
    /// address it was added with.
    func goHome() {
        if isSatelliteGroup {
            current.goHome()
        } else {
            select(0)
            home.goHome()
        }
    }

    func reloadAll() { tabs.forEach { $0.reloadIfLoaded() } }

    func teardown() {
        tabs.forEach { $0.teardown() }
    }
}

// MARK: - Tab bar

/// One tab: a title and (for closable tabs) a close button. A group's tabs show a thin band of its color.
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

    init(title: String, selected: Bool, closable: Bool, groupColor: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)

        if let groupColor {
            accent.backgroundColor = groupColor.cgColor
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

/// The colored pill at the start of a group's tab bar: a back chevron and the group's name. Clicking it goes back
/// to the list of groups.
final class GroupChipView: NSView {
    var onClick: (() -> Void)?
    private let color: NSColor

    init(name: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        toolTip = "Back to Tab Groups"

        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to Tab Groups")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))!)
        chevron.contentTintColor = color
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Back to Tab Groups from \(name)")
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor }
    }
}

/// A strip of tabs above the web content. An app's shows once it has more than one tab; a group's always shows,
/// starting with its chip (`GroupChipView`).
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The right-click menu of the tab at an index.
    var menuForTab: ((Int) -> NSMenu?)?
    /// The group's chip was clicked.
    var onChipClick: (() -> Void)?

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill   // the chip is narrower than the tabs; .fillEqually would stretch it
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

    /// Rebuilds the bar from `group`'s current tabs, with a chip first for a Satellite group. Cheap enough to call
    /// on every title change too.
    func show(_ group: TabGroup, chip: (name: String, color: GroupColor)? = nil) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let chip {
            let view = GroupChipView(name: chip.name, color: chip.color.nsColor)
            view.onClick = { [weak self] in self?.onChipClick?() }
            stack.addArrangedSubview(view)
        }
        for (index, pane) in group.tabs.enumerated() {
            let button = TabButton(title: pane.tabTitle, selected: index == group.selectedIndex,
                                   closable: group.canClose(index), groupColor: chip?.color.nsColor)
            button.onSelect = { [weak self] in self?.onSelect?(index) }
            button.onClose = { [weak self] in self?.onClose?(index) }
            button.makeMenu = { [weak self] in self?.menuForTab?(index) }
            stack.addArrangedSubview(button)
        }
    }
}
