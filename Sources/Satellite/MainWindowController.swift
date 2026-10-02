import AppKit

extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("satellite.back")
    static let forward = NSToolbarItem.Identifier("satellite.forward")
    static let reload = NSToolbarItem.Identifier("satellite.reload")
    static let toggleAssistants = NSToolbarItem.Identifier("satellite.toggleAssistants")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    private let registry = UIRegistry.shared
    private let railVC = RailViewController()
    private let contentVC = ContentViewController()
    private let assistantsVC = AssistantsViewController()
    private let assistantsItem: NSSplitViewItem
    private var observers: [NSObjectProtocol] = []

    init(openSettings: @escaping () -> Void) {
        let split = NSSplitViewController()
        let railItem = NSSplitViewItem(sidebarWithViewController: railVC)
        railItem.minimumThickness = 76
        railItem.maximumThickness = 76
        railItem.canCollapse = false
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 480
        assistantsItem = NSSplitViewItem(inspectorWithViewController: assistantsVC)
        assistantsItem.minimumThickness = 340
        assistantsItem.maximumThickness = 760
        assistantsItem.canCollapse = true
        split.addSplitViewItem(railItem)
        split.addSplitViewItem(contentItem)
        split.addSplitViewItem(assistantsItem)
        split.splitView.autosaveName = "SatelliteSplit"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1500, height: 920))
        window.minSize = NSSize(width: 960, height: 560)
        window.toolbarStyle = .unified
        window.center()
        window.setFrameAutosaveName("SatelliteMainWindow")

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "SatelliteToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        railVC.onSelect = { [weak self] in self?.selectApp($0) }
        railVC.onOpenSettings = openSettings

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .webPaneStateChanged, object: nil, queue: .main) { [weak self] _ in
                self?.window?.toolbar?.validateVisibleItems()
            },
            center.addObserver(forName: UIRegistry.changed, object: nil, queue: .main) { [weak self] _ in
                self?.applyItems()
            },
            center.addObserver(forName: UIRegistry.selectRequested, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?["section"] as? String, let section = SidebarSection(rawValue: raw),
                      let id = note.userInfo?["id"] as? String else { return }
                switch section {
                case .apps: self?.selectApp(id)
                case .assistants: self?.showAssistant(id)
                }
            },
        ]

        applyItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Sidebar items

    /// Brings the rail, the content area and the assistants panel in line with the registry.
    private func applyItems() {
        let apps = registry.items(.apps)
        contentVC.setItems(apps)
        railVC.setItems(apps)
        assistantsVC.setItems(registry.items(.assistants))

        if let current = contentVC.selectedID, let item = apps.first(where: { $0.id == current }) {
            railVC.setSelected(current)
            window?.title = item.name
        } else {
            let saved = UserDefaults.standard.string(forKey: "lastSelectedAppID")
            selectApp(apps.first { $0.id == saved }?.id ?? apps.first?.id)
        }
    }

    func selectApp(_ id: String?) {
        guard let id, let item = registry.items(.apps).first(where: { $0.id == id }) else { return }
        contentVC.select(id)
        railVC.setSelected(id)
        window?.title = item.name
        UserDefaults.standard.set(id, forKey: "lastSelectedAppID")
        window?.toolbar?.validateVisibleItems()
    }

    func showAssistant(_ id: String) {
        if assistantsItem.isCollapsed { assistantsItem.animator().isCollapsed = false }
        assistantsVC.select(id)
    }

    // MARK: Actions

    @objc func toggleAssistants(_ sender: Any?) {
        assistantsItem.animator().isCollapsed.toggle()
    }

    @objc func goBack(_ sender: Any?) { activePane?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { activePane?.webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { activePane?.webView.reload() }
    @objc func hardReloadPage(_ sender: Any?) { activePane?.webView.reloadFromOrigin() }

    func reloadAllPages() {
        contentVC.reloadAll()
        assistantsVC.reloadAll()
    }

    /// Navigation commands act on whichever side (apps or assistants) has focus.
    private var activePane: WebPane? {
        if let view = window?.firstResponder as? NSView,
           view.isDescendant(of: assistantsVC.view),
           let pane = assistantsVC.selectedPane {
            return pane
        }
        return contentVC.selectedPane
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .reload, .flexibleSpace, .toggleAssistants]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func make(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch identifier {
        case .back: return make("chevron.left", "Back", #selector(goBack(_:)))
        case .forward: return make("chevron.right", "Forward", #selector(goForward(_:)))
        case .reload: return make("arrow.clockwise", "Reload", #selector(reloadPage(_:)))
        case .toggleAssistants: return make("sidebar.right", "Toggle Assistants", #selector(toggleAssistants(_:)))
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .back: return activePane?.webView.canGoBack ?? false
        case .forward: return activePane?.webView.canGoForward ?? false
        default: return true
        }
    }
}
