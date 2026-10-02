import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController?
    private let viewMenu = NSMenu(title: "View")
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = AppConfig.load()
        UIRegistry.shared.configure(config)
        ExtensionManager.shared.reload()

        let controller = MainWindowController(openSettings: { [weak self] in self?.openSettings() })
        mainController = controller
        SettingsWindowController.shared.onReloadPages = { [weak controller] in controller?.reloadAllPages() }

        buildMenu()
        menuObserver = NotificationCenter.default.addObserver(forName: UIRegistry.changed, object: nil, queue: .main) { [weak self] _ in
            self?.populateViewMenu()
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The window closes but sessions stay alive; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainController?.showWindow(nil) }
        return true
    }

    // MARK: Actions

    @objc private func openSettings() { SettingsWindowController.shared.present() }
    @objc private func goBack() { mainController?.goBack(nil) }
    @objc private func goForward() { mainController?.goForward(nil) }
    @objc private func reloadPage() { mainController?.reloadPage(nil) }
    @objc private func hardReloadPage() { mainController?.hardReloadPage(nil) }
    @objc private func toggleAssistants() { mainController?.toggleAssistants(nil) }
    @objc private func selectApp(_ sender: NSMenuItem) { mainController?.selectApp(sender.representedObject as? String) }
    @objc private func showAssistant(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { mainController?.showAssistant(id) }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(editMenu()))
        populateViewMenu()
        main.addItem(submenu(viewMenu))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, represented: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menuItem.target = target
        menuItem.representedObject = represented
        return menuItem
    }

    private func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings\u{2026}", #selector(openSettings), ",", target: self))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// Rebuilt whenever the sidebar changes so the app and assistant shortcuts follow it.
    private func populateViewMenu() {
        viewMenu.removeAllItems()
        viewMenu.addItem(item("Back", #selector(goBack), "[", target: self))
        viewMenu.addItem(item("Forward", #selector(goForward), "]", target: self))
        viewMenu.addItem(item("Reload Page", #selector(reloadPage), "r", target: self))
        viewMenu.addItem(item("Reload Without Cache", #selector(hardReloadPage), "r", [.command, .shift], target: self))
        viewMenu.addItem(.separator())
        for (index, app) in UIRegistry.shared.items(.apps).prefix(9).enumerated() {
            viewMenu.addItem(item(app.name, #selector(selectApp(_:)), "\(index + 1)", target: self, represented: app.id))
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Toggle Assistants", #selector(toggleAssistants), "0", [.command, .option], target: self))
        for (index, assistant) in UIRegistry.shared.items(.assistants).prefix(9).enumerated() {
            viewMenu.addItem(item(assistant.name, #selector(showAssistant(_:)), "\(index + 1)", [.command, .option], target: self, represented: assistant.id))
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
