import AppKit

/// The application object. It reads key presses before AppKit does, so shortcuts can be told apart exactly
/// (see `ShortcutRegistry.intercept`).
final class SatelliteApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, ShortcutRegistry.shared.intercept(event) { return }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController?
    private let shortcuts = ShortcutRegistry.shared
    private var observers: [NSObjectProtocol] = []

    private let appMenu = NSMenu(title: ProcessInfo.processInfo.processName)
    private let fileMenu = NSMenu(title: "File")
    private let editMenu = NSMenu(title: "Edit")
    private let viewMenu = NSMenu(title: "View")
    private let extensionsMenu = NSMenu(title: "Extensions")
    private let windowMenu = NSMenu(title: "Window")
    private var extensionsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UIRegistry.shared.configure(AppsModel.shared.config)
        ExtensionManager.shared.reload()

        let controller = MainWindowController(openSettings: { [weak self] in self?.openSettings() })
        mainController = controller
        SettingsWindowController.shared.onReloadPages = { [weak controller] in controller?.reloadAllPages() }
        SettingsWindowController.shared.currentPageURL = { [weak controller] in controller?.currentPageURL }

        shortcuts.setAppCommands(BuiltInCommands.make(window: controller, app: AppActions(
            openSettings: { [weak self] in self?.openSettings() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            closeTabOrWindow: { [weak self] in self?.closeTabOrWindow() },
            closeTitle: { [weak self] in self?.closeTitle ?? "Close" })))
        shortcuts.frontWebView = { [weak controller] in
            guard let controller, controller.window?.isKeyWindow == true, let pane = controller.activePane, pane.didCreateView else { return nil }
            return pane.webView
        }
        syncSidebarShortcuts()

        buildMenu()
        observers = [
            NotificationCenter.default.addObserver(forName: UIRegistry.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSidebarShortcuts() }
            },
            NotificationCenter.default.addObserver(forName: ShortcutRegistry.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.populateMenus() }
            },
        ]
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        UpdateChecker.shared.startPeriodicChecks()
        FIDODeviceMonitor.shared.start()
        ExtensionWatcher.shared.start()
    }

    // The window closes but sessions stay alive; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainController?.showWindow(nil) }
        return true
    }

    // MARK: Actions

    private func openSettings() { SettingsWindowController.shared.present() }
    private func checkForUpdates() { Task { @MainActor in UpdateChecker.shared.check(silent: false) } }

    private var hasClosableTab: Bool {
        NSApp.keyWindow === mainController?.window && mainController?.hasClosableTab == true
    }
    private var closeTitle: String { hasClosableTab ? "Close Tab" : "Close" }

    /// Closes the current tab if there is one to close, otherwise the window in front.
    private func closeTabOrWindow() {
        if NSApp.keyWindow === mainController?.window, mainController?.closeCurrentTab() == true { return }
        NSApp.keyWindow?.performClose(nil)
    }

    /// Each app and assistant of the sidebar gets a command, so it has a shortcut Settings can change.
    private func syncSidebarShortcuts() {
        shortcuts.setSidebar(
            apps: UIRegistry.shared.items(.apps), assistants: UIRegistry.shared.items(.assistants),
            selectApp: { [weak self] in self?.mainController?.selectApp($0) },
            showAssistant: { [weak self] in self?.mainController?.showAssistant($0) })
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        main.addItem(submenu(appMenu))
        main.addItem(submenu(fileMenu))
        main.addItem(submenu(editMenu))
        main.addItem(submenu(viewMenu))
        let extensions = submenu(extensionsMenu)
        extensions.isHidden = true
        extensionsItem = extensions
        main.addItem(extensions)
        main.addItem(submenu(windowMenu))
        populateMenus()
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Rebuilt whenever a shortcut, the sidebar or an extension's commands change, so the menus always show
    /// (and answer to) the shortcuts in use.
    private func populateMenus() {
        fill(appMenu, MenuLayout.app)
        fill(fileMenu, MenuLayout.file)
        fill(editMenu, MenuLayout.edit)
        fill(viewMenu, MenuLayout.view)
        fill(windowMenu, MenuLayout.window)
        populateExtensionsMenu()
    }

    private func fill(_ menu: NSMenu, _ layout: [String?]) {
        menu.removeAllItems()
        for entry in layout {
            switch entry {
            case nil: menu.addItem(.separator())
            case "@apps": add(commands(in: "Apps", source: .sidebar), to: menu)
            case "@assistants": add(commands(in: "Assistants", source: .sidebar), to: menu)
            case let id?: add([id], to: menu)
            }
        }
    }

    private func commands(in group: String, source: ShortcutCommand.Source) -> [String] {
        shortcuts.commands.filter { $0.group == group && $0.source == source }.map(\.id)
    }

    private func add(_ ids: [String], to menu: NSMenu) {
        for id in ids { if let item = shortcuts.menuItem(for: id) { menu.addItem(item) } }
    }

    /// Commands that extensions registered, under the name of the extension. The menu only shows up when there are any.
    private func populateExtensionsMenu() {
        extensionsMenu.removeAllItems()
        var owners: [String] = []
        for command in shortcuts.commands {
            if let owner = command.owner, !owners.contains(owner) { owners.append(owner) }
        }
        for owner in owners {
            extensionsMenu.addItem(.sectionHeader(title: ExtensionManager.shared.info(owner)?.displayName ?? owner))
            add(shortcuts.commands.filter { $0.owner == owner }.map(\.id), to: extensionsMenu)
        }
        extensionsItem?.isHidden = owners.isEmpty
    }
}
