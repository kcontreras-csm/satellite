import AppKit

/// The parts of the app's commands that belong to the app rather than to the window.
struct AppActions {
    var openSettings: () -> Void
    var checkForUpdates: () -> Void
    /// Closes the tab in front if there is one to close, otherwise the window.
    var closeTabOrWindow: () -> Void
    /// "Close Tab" when there is a tab to close, otherwise "Close".
    var closeTitle: () -> String
}

/// Which commands each menu holds, in order. `nil` is a separator; "@apps" and "@assistants" stand for the
/// sidebar's items, which come and go.
enum MenuLayout {
    static let app: [String?] = [
        "app.about", "app.updates", nil, "app.settings", nil,
        "app.hide", "app.hideOthers", "app.showAll", nil, "app.quit",
    ]
    static let file: [String?] = [
        "page.print", nil, "page.copyAddress", "page.openInBrowser", nil, "window.close",
    ]
    static let edit: [String?] = [
        "edit.undo", "edit.redo", nil, "edit.cut", "edit.copy", "edit.paste", "edit.selectAll", nil,
        "page.find", "page.findNext", "page.findPrevious", nil,
        "find.regex", "find.caseSensitive", "find.wholeWord",
    ]
    static let view: [String?] = [
        "nav.back", "nav.forward", "nav.reload", "nav.hardReload", "nav.stop", "nav.home", nil,
        "@apps", nil,
        "nav.nextTab", "nav.previousTab", nil,
        "assistants.toggle", "@assistants", nil,
        "page.zoomIn", "page.zoomOut", "page.zoomReset", nil,
        "ai.copy", "ai.save", nil,
        "window.fullScreen",
    ]
    static let window: [String?] = [
        "window.minimize", "window.zoom", nil, "window.front",
    ]
}

/// Every command of the app, each with the shortcut it starts out with. What the user changes is kept by
/// `ShortcutRegistry`, so these stay the defaults.
@MainActor
enum BuiltInCommands {
    static func make(window: MainWindowController, app: AppActions) -> [ShortcutCommand] {
        let name = ProcessInfo.processInfo.processName

        func command(_ id: String, _ title: String, _ group: String, key shortcut: String? = nil, fixed: Bool = false,
                     _ action: ShortcutCommand.Action) -> ShortcutCommand {
            let combo = shortcut.flatMap { try? KeyCombo(parsing: $0) }
            assert(shortcut == nil || combo != nil, "\(id): \(shortcut ?? "") is not a valid shortcut")
            var result = ShortcutCommand(id: id, title: title, group: group, defaultCombo: combo, action: action)
            result.isFixed = fixed
            return result
        }
        func run(_ body: @escaping @MainActor () -> Void) -> ShortcutCommand.Action { .run(body) }

        /// A find option that shows as ticked in the menu while it is on.
        func findOption(_ id: String, _ title: String, _ shortcut: String, _ option: WritableKeyPath<FindOptions, Bool>) -> ShortcutCommand {
            var result = command(id, title, "Page", key: shortcut, run { window.toggleFindOption(option) })
            result.validate = { item in
                item.state = FindOptions.current[keyPath: option] ? .on : .off
                return true
            }
            return result
        }

        var close = command("window.close", "Close", "Window", key: "Cmd+W", fixed: true, run(app.closeTabOrWindow))
        close.validate = { item in
            item.title = app.closeTitle()
            return true
        }

        return [
            // App
            command("app.about", "About \(name)", "App", fixed: true, .responder(#selector(NSApplication.orderFrontStandardAboutPanel(_:)))),
            command("app.updates", "Check for Updates\u{2026}", "App", run(app.checkForUpdates)),
            command("app.settings", "Settings\u{2026}", "App", key: "Cmd+,", fixed: true, run(app.openSettings)),
            command("app.hide", "Hide \(name)", "App", key: "Cmd+H", fixed: true, .responder(#selector(NSApplication.hide(_:)))),
            command("app.hideOthers", "Hide Others", "App", key: "Cmd+Alt+H", fixed: true, .responder(#selector(NSApplication.hideOtherApplications(_:)))),
            command("app.showAll", "Show All", "App", fixed: true, .responder(#selector(NSApplication.unhideAllApplications(_:)))),
            command("app.quit", "Quit \(name)", "App", key: "Cmd+Q", fixed: true, .responder(#selector(NSApplication.terminate(_:)))),

            // Edit
            command("edit.undo", "Undo", "Edit", key: "Cmd+Z", fixed: true, .responder(Selector(("undo:")))),
            command("edit.redo", "Redo", "Edit", key: "Cmd+Shift+Z", fixed: true, .responder(Selector(("redo:")))),
            command("edit.cut", "Cut", "Edit", key: "Cmd+X", fixed: true, .responder(#selector(NSText.cut(_:)))),
            command("edit.copy", "Copy", "Edit", key: "Cmd+C", fixed: true, .responder(#selector(NSText.copy(_:)))),
            command("edit.paste", "Paste", "Edit", key: "Cmd+V", fixed: true, .responder(#selector(NSText.paste(_:)))),
            command("edit.selectAll", "Select All", "Edit", key: "Cmd+A", fixed: true, .responder(#selector(NSText.selectAll(_:)))),

            // Navigation
            command("nav.back", "Back", "Navigation", key: "Cmd+[", run { window.goBack(nil) }),
            command("nav.forward", "Forward", "Navigation", key: "Cmd+]", run { window.goForward(nil) }),
            command("nav.reload", "Reload Page", "Navigation", key: "Cmd+R", run { window.reloadPage(nil) }),
            command("nav.hardReload", "Reload Without Cache", "Navigation", key: "Cmd+Shift+R", run { window.hardReloadPage(nil) }),
            command("nav.stop", "Stop Loading", "Navigation", key: "Cmd+.", run { window.stopLoading() }),
            command("nav.home", "Go to Start Page", "Navigation", key: "Cmd+Shift+H", run { window.goHome() }),
            command("nav.nextTab", "Show Next Tab", "Navigation", key: "Cmd+Shift+]", run { window.showNextTab() }),
            command("nav.previousTab", "Show Previous Tab", "Navigation", key: "Cmd+Shift+[", run { window.showPreviousTab() }),

            // Page
            command("page.find", "Find\u{2026}", "Page", key: "Cmd+F", run { window.showFind() }),
            command("page.findNext", "Find Next", "Page", key: "Cmd+G", run { window.find(forward: true) }),
            command("page.findPrevious", "Find Previous", "Page", key: "Cmd+Shift+G", run { window.find(forward: false) }),
            findOption("find.regex", "Use Regular Expression", "Cmd+Alt+R", \.regex),
            findOption("find.caseSensitive", "Match Case", "Cmd+Alt+C", \.caseSensitive),
            findOption("find.wholeWord", "Match Whole Word", "Cmd+Alt+W", \.wholeWord),
            command("page.zoomIn", "Zoom In", "Page", key: "Cmd+=", run { window.zoom(.larger) }),
            command("page.zoomOut", "Zoom Out", "Page", key: "Cmd+-", run { window.zoom(.smaller) }),
            command("page.zoomReset", "Actual Size", "Page", key: "Cmd+0", run { window.zoom(.reset) }),
            command("page.print", "Print\u{2026}", "Page", key: "Cmd+P", run { window.printPage() }),
            command("page.copyAddress", "Copy Page Address", "Page", key: "Cmd+Shift+L", run { window.copyPageAddress() }),
            command("page.openInBrowser", "Open in Default Browser", "Page", key: "Cmd+Shift+O", run { window.openInBrowser() }),

            // Assistants and AI
            command("assistants.toggle", "Toggle Assistants", "Assistants", key: "Cmd+Alt+0", run { window.toggleAssistants(nil) }),
            command("ai.copy", "Copy Page for AI", "AI", key: "Cmd+Shift+C", run { window.copySnapshot(nil) }),
            command("ai.save", "Save Page for AI\u{2026}", "AI", key: "Cmd+Shift+S", run { window.saveSnapshot(nil) }),

            // Window
            close,
            command("window.minimize", "Minimize", "Window", key: "Cmd+M", fixed: true, .responder(#selector(NSWindow.performMiniaturize(_:)))),
            command("window.zoom", "Zoom", "Window", fixed: true, .responder(#selector(NSWindow.performZoom(_:)))),
            command("window.fullScreen", "Enter Full Screen", "Window", key: "Cmd+Ctrl+F", .responder(#selector(NSWindow.toggleFullScreen(_:)))),
            command("window.front", "Bring All to Front", "Window", fixed: true, .responder(#selector(NSApplication.arrangeInFront(_:)))),
        ]
    }
}
