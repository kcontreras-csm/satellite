import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = AppConfig.load()
        ExtensionManager.shared.reload()

        let controller = MainWindowController(config: config, openSettings: { [weak self] in self?.openSettings() })
        mainController = controller
        SettingsWindowController.shared.onReloadPages = { [weak controller] in controller?.reloadAllPages() }

        buildMenu(config)
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
    @objc private func selectApp(_ sender: NSMenuItem) { mainController?.selectApp(sender.tag) }
    @objc private func showAssistant(_ sender: NSMenuItem) { mainController?.showAssistant(sender.tag) }

    // MARK: Menu

    private func buildMenu(_ config: AppConfig) {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(config)))
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
                      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menuItem.target = target
        menuItem.tag = tag
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

    private func viewMenu(_ config: AppConfig) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Back", #selector(goBack), "[", target: self))
        menu.addItem(item("Forward", #selector(goForward), "]", target: self))
        menu.addItem(item("Reload Page", #selector(reloadPage), "r", target: self))
        menu.addItem(item("Reload Without Cache", #selector(hardReloadPage), "r", [.command, .shift], target: self))
        menu.addItem(.separator())
        for (index, app) in config.apps.prefix(9).enumerated() {
            menu.addItem(item(app.name, #selector(selectApp(_:)), "\(index + 1)", target: self, tag: index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Toggle Assistants", #selector(toggleAssistants), "0", [.command, .option], target: self))
        for (index, assistant) in config.assistants.prefix(9).enumerated() {
            menu.addItem(item(assistant.name, #selector(showAssistant(_:)), "\(index + 1)", [.command, .option], target: self, tag: index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
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
