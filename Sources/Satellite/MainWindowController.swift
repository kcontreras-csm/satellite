import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("satellite.back")
    static let forward = NSToolbarItem.Identifier("satellite.forward")
    static let reload = NSToolbarItem.Identifier("satellite.reload")
    static let addressBar = NSToolbarItem.Identifier("satellite.addressBar")
    static let newTab = NSToolbarItem.Identifier("satellite.newTab")
    static let toggleAssistants = NSToolbarItem.Identifier("satellite.toggleAssistants")
    static let snapshot = NSToolbarItem.Identifier("satellite.snapshot")
}

/// The text inside the address bar: shows the current page's address, selects it all on click so it's one Cmd+C
/// away, and (only once Settings > General's toggle allows it) can be typed into to navigate.
final class AddressBarField: NSTextField {
    /// Right-click while not typing in it: the page's own menu (its link, Add to Group).
    var pageMenu: (() -> NSMenu?)?
    /// Right-click while typing in it: these follow the usual Cut, Copy and Paste.
    var editingMenuItems: (() -> [NSMenuItem])?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if !isEditable { currentEditor()?.selectAll(nil) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if currentEditor() == nil, let menu = pageMenu?() { return menu }
        return super.menu(for: event)
    }

    // While it's being typed in, its field editor asks its delegate (this field) for the menu.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let extra = editingMenuItems?() ?? []
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }

    // The ring follows focus itself; controlTextDidBeginEditing only arrives with the first keystroke.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, isEditable { (superview as? AddressBar)?.isFocused = true }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        (superview as? AddressBar)?.isFocused = false
    }
}

/// Safari's address bar look: a filled, rounded pill with a leading icon around a borderless field. Not an
/// `NSSearchField`, whose clear button would wipe the address in read-only mode and whose bezel barely shows in
/// a dark toolbar. Long addresses truncate inside the pill instead of widening it into the buttons next to it.
final class AddressBar: NSView {
    let field = AddressBarField()
    private let icon = NSImageView()
    private lazy var width = widthAnchor.constraint(equalToConstant: 640)
    var isFocused = false { didSet { needsDisplay = true } }

    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 720
    /// macOS 26's toolbar buttons are 34pt capsules; earlier ones are shorter and squarer.
    private static let height: CGFloat = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 34 : 28

    /// Takes as much of `available` as it may, within its minimum and maximum width.
    func fit(width available: CGFloat) {
        let target = min(max(available.rounded(.down), Self.minWidth), Self.maxWidth)
        if width.constant != target { width.constant = target }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            width,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Self.height / 2   // a capsule, like the toolbar buttons beside it
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        }
        layer.borderWidth = isFocused ? 2 : 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A click on the padding or the icon works like a click on the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? { field.menu(for: event) }
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSTextFieldDelegate {
    private let registry = UIRegistry.shared
    private let railVC = RailViewController()
    private let contentVC = ContentViewController()
    private let assistantsVC = AssistantsViewController()
    private let assistantsItem: NSSplitViewItem
    private var observers: [NSObjectProtocol] = []
    private let addressBar = AddressBar()
    private var addressField: AddressBarField { addressBar.field }
    private var isEditingAddress = false
    /// True while a New Tab's blank address field is editable only because of that (the setting itself is off);
    /// cleared, and the field re-locked, once that one address is committed or cancelled.
    private var isTemporaryAddressEdit = false
    let assistantSender = AssistantSender()

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
        // Centered in the window, as Safari does, rather than wherever the items before it happen to end.
        toolbar.centeredItemIdentifiers = [.addressBar]
        window.toolbar = toolbar
        // The title would take the toolbar's leading space and push the bar off center; the rail already shows
        // which app is in front, and the Window menu and Mission Control still use the title.
        window.titleVisibility = .hidden

        addressField.placeholderString = "Address"
        addressField.isSelectable = true   // copyable even while read-only
        addressField.delegate = self
        // The page in front's menu, as its tab and its app in the rail have; nothing on the groups list.
        addressField.pageMenu = { [weak self] in
            guard let self, let pane = self.currentWebsitePane else { return nil }
            return self.contentVC.pageMenu(for: pane)
        }
        addressField.editingMenuItems = { [weak self] in
            guard let self, let pane = self.currentWebsitePane else { return [] }
            return self.contentVC.groupMenuItems(for: pane)
        }
        applyAddressEditability()

        railVC.onSelect = { [weak self] in self?.selectApp($0) }
        railVC.menuForApp = { [weak self] in self?.contentVC.appMenu(for: $0) }
        railVC.onOpenSettings = openSettings
        railVC.onOpenGroups = { [weak self] in self?.showGroupsList() }
        contentVC.onSelectionChange = { [weak self] in self?.selectionChanged() }
        let groupsList = NSHostingView(rootView: GroupsListView(
            model: .shared, groups: contentVC.satelliteGroups, open: { [weak self] in self?.openGroup($0) }))
        // By default a hosting view turns its content's minimum size into required constraints. The list's is
        // taller than a screen, which made the window grow past the screen's bottom edge (hiding the rail's
        // Groups and Settings buttons) and pinned it to the top. It just fills whatever room the content area has.
        groupsList.sizingOptions = []
        contentVC.setGroupsList(groupsList)

        contentVC.view.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .webPaneStateChanged, object: nil, queue: .main) { [weak self] _ in
                self?.window?.toolbar?.validateVisibleItems()
                self?.refreshAddressField()
            },
            center.addObserver(forName: UIRegistry.changed, object: nil, queue: .main) { [weak self] _ in
                self?.applyItems()
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.fitAddressBar()
            },
            // Showing, hiding or dragging the assistants panel changes the page column the bar is centered on. The
            // split view's own resize notification arrives before the column has its new frame; this doesn't.
            center.addObserver(forName: NSView.frameDidChangeNotification, object: contentVC.view, queue: .main) { [weak self] _ in
                self?.fitAddressBar()
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

        SatelliteWebView.menuExtender = { [weak self] view, menu in
            guard let self else { return }
            AssistantContextMenu.extend(
                menu, isAssistantPage: view.pane?.isAssistant ?? false, assistants: self.registry.items(.assistants),
                preferredID: self.assistantsVC.selectedID,
                ask: { [weak self, weak view] id in
                    guard let pane = view?.pane else { return }
                    self?.send(from: pane, assistantID: id, selectionOnly: true)
                })
        }
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

        switch contentVC.selection {
        case .app(let current) where apps.contains(where: { $0.id == current }):
            selectionChanged()   // its name, or its "Allow editing the address bar", may have just changed in Settings
        case .groupsList, .group:
            selectionChanged()   // still showing groups; an app being edited mustn't pull the view away from them
        default:
            let saved = UserDefaults.standard.string(forKey: "lastSelectedAppID")
            selectApp(apps.first { $0.id == saved }?.id ?? apps.first?.id)
        }
    }

    func selectApp(_ id: String?) {
        guard let id, registry.items(.apps).contains(where: { $0.id == id }) else { return }
        contentVC.select(id)
        UserDefaults.standard.set(id, forKey: "lastSelectedAppID")
        selectionChanged()
    }

    /// Groups in the rail: the list of tab groups in place of the pages.
    func showGroupsList() {
        contentVC.showGroupsList()
        selectionChanged()
    }

    /// Shows a tab group's pages, loading it first if it isn't.
    func openGroup(_ id: String) {
        if contentVC.openGroup(id) { selectionChanged() }
    }

    /// The rail, the title and the toolbar follow whatever the content area shows now.
    private func selectionChanged() {
        switch contentVC.selection {
        case .app(let id):
            railVC.setGroupsSelected(false)
            railVC.setSelected(id)
            window?.title = registry.items(.apps).first { $0.id == id }?.name ?? ""
        case .groupsList:
            railVC.setSelected(nil)
            railVC.setGroupsSelected(true)
            window?.title = "Tab Groups"
        case .group(let id):
            railVC.setSelected(nil)
            railVC.setGroupsSelected(true)
            window?.title = contentVC.satelliteGroups.group(id)?.name ?? "Tab Groups"
        case nil:
            break
        }
        window?.toolbar?.validateVisibleItems()
        applyAddressEditability()
        refreshAddressField()
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
        if let terminal = focusedTerminal {
            Toast.show("Text size \(Int(terminal.zoom(change))) pt", in: window, duration: 1.2)
            return
        }
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

    /// Copies the link of the page in front: the current tab of the app, or the focused assistant.
    func copyPageAddress(withTitle: Bool = false) {
        guard let pane = activePane, let url = pane.currentURL, PageLink.isShareable(url) else {
            Toast.show("Open a page first", in: window)
            return
        }
        PageLink.copy(url, title: pane.tabTitle, includeTitle: withTitle)
        Toast.show(withTitle ? "Copied \u{201C}\(pane.tabTitle)\u{201D} with its link" : "Copied link", in: window)
    }

    func openInBrowser() {
        guard let url = activePane?.webView.url else {
            Toast.show("Open a page first", in: window)
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Sending to an assistant

    /// The assistant that sending goes to: the one shown in the side panel.
    var targetAssistant: SidebarItem? {
        let assistants = registry.items(.assistants)
        return assistants.first { $0.id == assistantsVC.selectedID } ?? assistants.first
    }

    /// Sends the selection of the app page in front, or the whole page if nothing is selected.
    func sendToAssistant() {
        send(from: contentVC.selectedPane, assistantID: nil, selectionOnly: false)
    }

    @objc func sendToAssistantAction(_ sender: Any?) { sendToAssistant() }

    func send(from source: WebPane?, assistantID: String?, selectionOnly: Bool) {
        guard let source else {
            Toast.show("Open a page first", in: window)
            return
        }
        let assistants = registry.items(.assistants)
        guard let assistant = assistants.first(where: { $0.id == assistantID }) ?? targetAssistant else {
            Toast.show("Add an assistant in Settings > Apps first", in: window)
            return
        }
        window?.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            await assistantSender.send(from: source, to: assistant, selectionOnly: selectionOnly, window: window) { [weak self] id in
                guard let self else { return nil }
                self.showAssistant(id)
                guard self.assistantsVC.selectedID == id else { return nil }
                if let terminal = self.assistantsVC.selectedTerminal { return .terminal(terminal) }
                return self.assistantsVC.selectedPane.map { .page($0) }
            }
        }
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

    /// Navigation commands act on whichever side (apps or assistants) has focus. While a terminal in the assistants
    /// panel has it there is no page: Reload, Find, Back... typed in the terminal must not reach past it to the app.
    var activePane: WebPane? {
        if let view = window?.firstResponder as? NSView, view.isDescendant(of: assistantsVC.view) {
            return assistantsVC.selectedPane
        }
        return contentVC.selectedPane
    }

    /// The page open in the apps panel, regardless of which side has focus — what "Send to Assistant" sends, and
    /// what Satellite's local MCP server (`MCPBridge`) shares with an agent that asks to read "the website".
    var currentWebsitePane: WebPane? { contentVC.selectedPane }

    /// Every page open in Satellite: each app's tabs (rail order), each loaded tab group's, then the web assistants.
    func openPages() -> [OpenPage] { contentVC.openPages + assistantsVC.openPages }

    /// The saved tab groups and which are loaded, for `MCPBridge`.
    var satelliteGroups: SatelliteGroups { contentVC.satelliteGroups }

    /// The page with this `pageID`, whichever app or assistant it's in.
    func page(withID id: String) -> OpenPage? {
        openPages().first { $0.pane.pageID == id.lowercased() }
    }

    /// The current tab of the app, loaded tab group or web assistant with this id or name (case-insensitive).
    func currentPage(ofApp identifier: String) -> OpenPage? {
        openPages().first {
            $0.isCurrentTab && ($0.ownerID == identifier || $0.owner.localizedCaseInsensitiveCompare(identifier) == .orderedSame)
        }
    }

    var hasTerminal: Bool { assistantsVC.firstTerminalID != nil }

    /// Opens the theme list of the terminal in the panel (the first terminal, when another assistant is shown).
    func chooseTerminalTheme() {
        guard let id = assistantsVC.selectedTerminal?.id ?? assistantsVC.firstTerminalID else { return }
        showAssistant(id)
        assistantsVC.selectedTerminal?.showThemePicker()
    }

    /// The terminal in the assistants panel, while it has focus.
    var focusedTerminal: TerminalPane? {
        guard let terminal = assistantsVC.selectedTerminal, let view = window?.firstResponder as? NSView,
              view.isDescendant(of: terminal.view) else { return nil }
        return terminal
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Navigation leading, the address bar centered (see centeredItemIdentifiers), page actions trailing.
        [.back, .forward, .flexibleSpace, .addressBar, .flexibleSpace, .reload, .newTab, .snapshot, .toggleAssistants]
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
            for (title, action) in [("Copy Page for AI", #selector(copySnapshot(_:))), ("Save Page for AI\u{2026}", #selector(saveSnapshot(_:))),
                                    ("Send to Assistant", #selector(sendToAssistantAction(_:)))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            item.menu = menu
            return item
        case .back: return make("chevron.left", "Back", #selector(goBack(_:)))
        case .forward: return make("chevron.right", "Forward", #selector(goForward(_:)))
        case .reload: return make("arrow.clockwise", "Reload", #selector(reloadPage(_:)))
        case .newTab: return make("plus", "New Tab", #selector(newTab(_:)))
        case .toggleAssistants: return make("sidebar.right", "Toggle Assistants", #selector(toggleAssistants(_:)))
        case .addressBar:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Address"
            item.view = addressBar
            item.visibilityPriority = .high   // the last thing to go to the overflow menu in a narrow window
            refreshAddressField()
            return item
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

    // MARK: Address bar

    /// Room the system's toolbar buttons take, measured on macOS 26 (earlier versions' are smaller, which only
    /// leaves the bar more slack): Back and Forward end 90pt into the page column; Reload, New Tab, Page for AI and
    /// the panel toggle start 215pt before the window's trailing edge.
    private static let leadingButtonsWidth: CGFloat = 90
    private static let trailingButtonsWidth: CGFloat = 215

    /// The toolbar centers the bar over the page column (between the rail and the assistants panel) but won't
    /// shrink it to fit there, so it would push into the buttons or over the panel. This sizes it to the widest
    /// it can be while centered there and clear of the buttons on both sides.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        fitAddressBar()
    }

    private func fitAddressBar() {
        guard let window else { return }
        let column = contentVC.view.convert(contentVC.view.bounds, to: nil)
        guard column.width > 0 else { return }
        let gap: CGFloat = 12
        let left = column.midX - (column.minX + Self.leadingButtonsWidth + gap)
        let right = min(column.maxX, window.frame.width - Self.trailingButtonsWidth) - gap - column.midX
        addressBar.fit(width: 2 * min(left, right))
    }

    /// Shows the address of the front app's current tab (not whatever the assistants panel shows), so it stays put
    /// while a terminal has focus instead of going blank. Does nothing while the user is actively typing into it,
    /// so an unrelated page's title or loading change elsewhere can't overwrite what they're mid-typing.
    private func refreshAddressField() {
        guard !isEditingAddress else { return }
        addressField.stringValue = currentWebsitePane?.webView.url?.absoluteString ?? ""
    }

    /// Whether the app in front has "Allow editing the address bar" on (Settings > Apps, or `editableAddress`).
    private var frontAppAllowsAddressEditing: Bool {
        registry.items(.apps).first { $0.id == contentVC.selectedID }?.editableAddress ?? false
    }

    /// Makes the bar editable or read-only for the app in front. Leaves it alone during a New Tab's one-off edit,
    /// which puts it back itself when that edit ends.
    private func applyAddressEditability() {
        guard !isTemporaryAddressEdit else { return }
        let editable = frontAppAllowsAddressEditing
        addressField.isEditable = editable
        addressField.toolTip = editable
            ? "The address of the page in front. Type an address and press Return to go there."
            : "The address of the page in front. Copy it with \u{2318}C; editing is off for this app in Settings > Apps."
        if !editable { refreshAddressField() }
    }

    private func navigateToTypedAddress() {
        guard let pane = currentWebsitePane else { return }
        let typed = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.url(from: typed) else { refreshAddressField(); return }
        pane.webView.load(URLRequest(url: url))
    }

    /// A typed address: used as-is if it already has a scheme, else tried as an https host.
    static func url(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil { return url }
        guard let url = URL(string: "https://" + text), url.host?.contains(".") == true else { return nil }
        return url
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addressField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            navigateToTypedAddress()
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === addressField else { return }
        isEditingAddress = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === addressField else { return }
        isEditingAddress = false
        if isTemporaryAddressEdit {
            isTemporaryAddressEdit = false
            applyAddressEditability()
        }
        refreshAddressField()
    }

    // MARK: New tab

    /// A blank tab in the app shown now. There's nowhere for it to go yet, so the address field is made editable
    /// just this once (even if the app doesn't allow editing it) and focused, ready to type into.
    @objc func newTab(_ sender: Any?) {
        guard let host = currentWebsitePane?.tabHost else { return }
        _ = host.openTab(configuration: WebEnvironment.makeConfiguration())
        if !addressField.isEditable {
            addressField.isEditable = true
            isTemporaryAddressEdit = true
        }
        addressField.stringValue = ""
        window?.makeFirstResponder(addressField)
    }
}
