import AppKit
import UniformTypeIdentifiers
import WebKit

extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("satellite.back")
    static let forward = NSToolbarItem.Identifier("satellite.forward")
    static let reload = NSToolbarItem.Identifier("satellite.reload")
    static let toggleAssistants = NSToolbarItem.Identifier("satellite.toggleAssistants")
    static let snapshot = NSToolbarItem.Identifier("satellite.snapshot")
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
            center.addObserver(forName: .extensionsHotReloaded, object: nil, queue: .main) { [weak self] note in
                guard let text = note.userInfo?["message"] as? String else { return }
                let prefix = note.userInfo?["isError"] as? Bool == true ? "\u{26A0}\u{FE0F} " : ""
                MainActor.assumeIsolated { Toast.show(prefix + text, in: self?.window, duration: 4) }
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
    func stopLoading() { activePane?.webView.stopLoading() }

    /// Back to the address the app (or assistant) in front started at.
    func goHome() {
        guard let pane = activePane else { return }
        if let group = pane.tabHost { group.goHome() } else { pane.goHome() }
    }

    /// The address of the page in front (for prefilling match patterns).
    var currentPageURL: URL? { activePane?.webView.url }

    // MARK: Page tools

    /// Opens the find bar on the page in front, starting with the text selected on it.
    func showFind() {
        guard let pane = activePane, pane.didCreateView else { return }
        pane.webView.evaluateJavaScript("String(window.getSelection())") { [weak pane] result, _ in
            let selected = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usable = !selected.isEmpty && selected.count <= 200 && !selected.contains("\n")
            pane?.findBar.show(prefill: usable ? selected : nil)
        }
    }

    /// Steps to the next or previous match, opening the find bar first if nothing has been searched for yet.
    func find(forward: Bool) {
        guard let pane = activePane, pane.didCreateView else { return }
        if pane.findBar.text.isEmpty { showFind() } else { pane.findBar.find(forward: forward) }
    }

    /// Switches a find option, opening the find bar first if it is closed so the change can be seen.
    func toggleFindOption(_ option: WritableKeyPath<FindOptions, Bool>) {
        FindOptions.current[keyPath: option].toggle()
        if let pane = activePane, pane.didCreateView, !pane.findBar.isShowing { showFind() }
    }

    func zoom(_ change: ZoomChange) {
        guard let pane = activePane, pane.didCreateView else { return }
        let level = pane.zoom(change)
        Toast.show("Zoom \(Int((level * 100).rounded()))%", in: window, duration: 1.2)
    }

    func printPage() {
        guard let pane = activePane, pane.didCreateView, pane.webView.url != nil else {
            Toast.show("Open a page first", in: window)
            return
        }
        pane.printPage(in: window)
    }

    func copyPageAddress() {
        guard let url = activePane?.webView.url else {
            Toast.show("Open a page first", in: window)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show("Copied page address", in: window)
    }

    func openInBrowser() {
        guard let url = activePane?.webView.url else {
            Toast.show("Open a page first", in: window)
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Tabs

    var hasClosableTab: Bool { contentVC.hasClosableTab }
    func showNextTab() { contentVC.nextTab() }
    func showPreviousTab() { contentVC.previousTab() }
    /// Closes the current tab if it is not the app's own. Returns whether it did.
    func closeCurrentTab() -> Bool { contentVC.closeCurrentTab() }

    // MARK: Page snapshots

    @objc func copySnapshot(_ sender: Any?) {
        takeSnapshot { [weak self] text, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Copied page for AI (\(Self.size(of: text)))", in: self?.window)
        }
    }

    @objc func saveSnapshot(_ sender: Any?) {
        takeSnapshot { [weak self] text, pane in
            guard let self, let window = self.window else { return }
            Toast.dismiss()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = Self.fileName(for: pane.webView)
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    Toast.show("Saved \(url.lastPathComponent) (\(Self.size(of: text)))", in: window)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func takeSnapshot(deliver: @escaping (String, WebPane) -> Void) {
        guard let pane = activePane, pane.didCreateView, pane.webView.url != nil else {
            Toast.show("Open a page first", in: window)
            return
        }
        Toast.show("Capturing page\u{2026}", in: window, duration: nil)
        Task { @MainActor in
            do {
                deliver(try await PageSnapshot.capture(pane.webView), pane)
            } catch {
                Toast.dismiss()
                if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    private static func size(of text: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }

    private static func fileName(for webView: WKWebView) -> String {
        let parts = [webView.url?.host, webView.title].compactMap { $0 }.filter { !$0.isEmpty }
        let base = (parts.isEmpty ? ["page"] : parts).joined(separator: " - ")
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return String(safe.prefix(80)) + " (snapshot).md"
    }

    func reloadAllPages() {
        contentVC.reloadAll()
        assistantsVC.reloadAll()
    }

    /// Navigation commands act on whichever side (apps or assistants) has focus.
    var activePane: WebPane? {
        if let view = window?.firstResponder as? NSView,
           view.isDescendant(of: assistantsVC.view),
           let pane = assistantsVC.selectedPane {
            return pane
        }
        return contentVC.selectedPane
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .reload, .flexibleSpace, .snapshot, .toggleAssistants]
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
        case .snapshot:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Page for AI")
            item.label = "Page for AI"
            item.toolTip = "Copy this page for an AI (arrow for more)"
            item.showsIndicator = true
            item.target = self
            item.action = #selector(copySnapshot(_:))
            let menu = NSMenu()
            for (title, action) in [("Copy Page for AI", #selector(copySnapshot(_:))), ("Save Page for AI\u{2026}", #selector(saveSnapshot(_:)))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            item.menu = menu
            return item
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
