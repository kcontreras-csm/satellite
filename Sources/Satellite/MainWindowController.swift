import AppKit

extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("satellite.back")
    static let forward = NSToolbarItem.Identifier("satellite.forward")
    static let reload = NSToolbarItem.Identifier("satellite.reload")
    static let toggleAssistants = NSToolbarItem.Identifier("satellite.toggleAssistants")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    let config: AppConfig
    private let railVC: RailViewController
    private let contentVC: ContentViewController
    private let assistantsVC: AssistantsViewController
    private let assistantsItem: NSSplitViewItem
    private var stateObserver: NSObjectProtocol?

    init(config: AppConfig, openSettings: @escaping () -> Void) {
        self.config = config
        railVC = RailViewController(apps: config.apps)
        contentVC = ContentViewController(apps: config.apps)
        assistantsVC = AssistantsViewController(assistants: config.assistants)

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

        stateObserver = NotificationCenter.default.addObserver(
            forName: .webPaneStateChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }

        let last = UserDefaults.standard.integer(forKey: "lastSelectedApp")
        selectApp(config.apps.indices.contains(last) ? last : 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    // MARK: Actions

    func selectApp(_ index: Int) {
        guard config.apps.indices.contains(index) else { return }
        contentVC.select(index)
        railVC.setSelected(index)
        window?.title = config.apps[index].name
        UserDefaults.standard.set(index, forKey: "lastSelectedApp")
        window?.toolbar?.validateVisibleItems()
    }

    func showAssistant(_ index: Int) {
        guard config.assistants.indices.contains(index) else { return }
        if assistantsItem.isCollapsed { assistantsItem.animator().isCollapsed = false }
        assistantsVC.select(index)
    }

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
