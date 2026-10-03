import AppKit
import WebKit

/// One thing a keyboard shortcut can do: a menu command of the app, an item of the sidebar, or a command an
/// extension registered.
struct ShortcutCommand: Identifiable {
    enum Action {
        case run(@MainActor () -> Void)
        /// Sent down the responder chain: the standard AppKit commands (Hide, Copy, Full Screen...).
        case responder(Selector)
    }

    enum Source: Equatable {
        case app
        case sidebar
        case `extension`(String)
    }

    /// Stable, because the user's choices are saved under it: "nav.back", "app:okta", "<extension>/<id>".
    let id: String
    var title: String
    /// The section of Settings > Shortcuts it is listed under.
    var group: String
    var defaultCombo: KeyCombo?
    var action: Action
    var source: Source = .app
    /// Standard macOS shortcuts (Quit, Copy, ...): shown, but they can be neither changed nor taken.
    var isFixed = false
    /// Called as the menu opens, for titles that depend on state.
    var validate: (@MainActor (NSMenuItem) -> Bool)?

    var owner: String? {
        if case .extension(let id) = source { return id }
        return nil
    }
}

/// Every command with its shortcut. The menus are built from it, Settings edits it, and extensions add to it with
/// `satellite.shortcuts.register`.
///
/// What the user chose (another shortcut, or none) is saved per command and wins over a default. Two commands never
/// share a shortcut: standard macOS ones come first, then the user's choices, then defaults in the order the commands
/// were added, so an extension can never take a shortcut that is already in use. Call everything on the main thread.
final class ShortcutRegistry: NSObject, ObservableObject {
    static let shared = ShortcutRegistry()
    static let changed = Notification.Name("SatelliteShortcutsChanged")
    static let maxPerExtension = 12
    private static let defaultsKey = "shortcutOverrides"

    /// Bumped on every change so SwiftUI views refresh.
    @Published private(set) var revision = 0
    /// The page in front, which extension shortcuts are delivered to.
    var frontWebView: (() -> WKWebView?)?

    private var appCommands: [ShortcutCommand] = []
    private var sidebarCommands: [ShortcutCommand] = []
    private var extensionCommands: [ShortcutCommand] = []
    /// Command id -> "" when the user turned the shortcut off, otherwise the shortcut they chose.
    private var overrides: [String: String]
    private var resolved: [String: KeyCombo] = [:]
    private var holders: [KeyCombo: String] = [:]
    /// Command id -> the command that has the shortcut it wanted.
    private var blockedBy: [String: String] = [:]
    private var notifyScheduled = false

    private override init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        overrides = stored.filter { $0.value.isEmpty || (try? KeyCombo(parsing: $0.value)) != nil }
        super.init()
    }

    // MARK: Reading

    var commands: [ShortcutCommand] { appCommands + sidebarCommands + extensionCommands }

    func command(_ id: String) -> ShortcutCommand? { commands.first { $0.id == id } }

    /// The shortcut the command has right now.
    func combo(for id: String) -> KeyCombo? { resolved[id] }

    func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    var hasCustomizations: Bool { !overrides.isEmpty }

    /// The command that has the shortcut `id` asked for, when it could not get it.
    func blockingCommand(for id: String) -> ShortcutCommand? { blockedBy[id].flatMap(command) }

    /// The shortcut `id` asked for, when another command has it (for the "in use by" note).
    func wantedCombo(for id: String) -> KeyCombo? {
        guard blockedBy[id] != nil, let command = command(id) else { return nil }
        if let text = overrides[id], !text.isEmpty { return try? KeyCombo(parsing: text) }
        return command.defaultCombo
    }

    // MARK: Adding commands

    /// The commands of the app itself. Replaces any set earlier.
    func setAppCommands(_ commands: [ShortcutCommand]) {
        appCommands = commands
        refresh()
    }

    /// The sidebar's apps and assistants, each selectable with its own shortcut (Cmd+1... and Opt+Cmd+1...).
    func setSidebar(apps: [SidebarItem], assistants: [SidebarItem],
                    selectApp: @escaping (String) -> Void, showAssistant: @escaping (String) -> Void) {
        func numbered(_ items: [SidebarItem], prefix: String, group: String, modifiers: NSEvent.ModifierFlags,
                      open: @escaping (String) -> Void) -> [ShortcutCommand] {
            items.enumerated().map { index, item in
                ShortcutCommand(
                    id: "\(prefix):\(item.id)", title: item.name, group: group,
                    defaultCombo: index < 9 ? try? KeyCombo(key: "\(index + 1)", modifiers: modifiers) : nil,
                    action: .run { open(item.id) }, source: .sidebar)
            }
        }
        sidebarCommands = numbered(apps, prefix: "app", group: "Apps", modifiers: .command, open: selectApp)
            + numbered(assistants, prefix: "assistant", group: "Assistants", modifiers: [.command, .option], open: showAssistant)
        refresh()
    }

    // MARK: Extensions

    /// Adds a command for `owner`, or updates the one it registered under the same id (keeping the user's choice).
    /// Returns what the extension gets back from `satellite.shortcuts.register`.
    func register(owner: String, input: [String: Any]) throws -> [String: Any] {
        guard let local = input["id"] as? String, UIRegistry.isValidLocalID(local) else {
            throw ManifestError("Shortcut \u{201C}id\u{201D} must be 1\u{2013}40 letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} or \u{201C}_\u{201D}")
        }
        guard let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...60).contains(title.count) else {
            throw ManifestError("Shortcut \u{201C}title\u{201D} must be 1\u{2013}60 characters")
        }
        var combo: KeyCombo?
        if let raw = input["shortcut"], !(raw is NSNull) {
            guard let text = raw as? String else { throw ManifestError("\u{201C}shortcut\u{201D} must be text like Cmd+Shift+K") }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                do { combo = try KeyCombo(parsing: text) } catch { throw ManifestError("\u{201C}shortcut\u{201D}: \(error.localizedDescription)") }
            }
        }

        let id = "\(owner)/\(local)"
        let existing = extensionCommands.firstIndex { $0.id == id }
        if existing == nil, extensionCommands.filter({ $0.owner == owner }).count >= Self.maxPerExtension {
            throw ManifestError("An extension can register at most \(Self.maxPerExtension) shortcuts")
        }
        let command = ShortcutCommand(
            id: id, title: title, group: "Extensions", defaultCombo: combo,
            action: .run { [weak self] in self?.deliver(owner: owner, local: local) }, source: .extension(owner))
        if let existing { extensionCommands[existing] = command } else { extensionCommands.append(command) }
        refresh()
        return describe(command)
    }

    func unregister(owner: String, id local: String) {
        let before = extensionCommands.count
        extensionCommands.removeAll { $0.id == "\(owner)/\(local)" }
        if extensionCommands.count != before { refresh() }
    }

    /// What `satellite.shortcuts.list()` returns to `owner`.
    func describe(for owner: String) -> [[String: Any]] {
        extensionCommands.filter { $0.owner == owner }.map(describe)
    }

    func removeAll(owner: String) {
        let before = extensionCommands.count
        extensionCommands.removeAll { $0.owner == owner }
        if extensionCommands.count != before { refresh() }
    }

    /// Drops the commands of extensions that are no longer running.
    func prune(keeping active: Set<String>) {
        let before = extensionCommands.count
        extensionCommands.removeAll { !active.contains($0.owner ?? "") }
        if extensionCommands.count != before { refresh() }
    }

    /// Forgets what the user chose for an extension that was removed.
    func forgetChoices(owner: String) {
        let keys = overrides.keys.filter { $0.hasPrefix("\(owner)/") }
        guard !keys.isEmpty else { return }
        keys.forEach { overrides[$0] = nil }
        save()
        refresh()
    }

    private func describe(_ command: ShortcutCommand) -> [String: Any] {
        [
            "id": command.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? command.id,
            "title": command.title,
            "shortcut": resolved[command.id]?.text as Any? ?? NSNull(),
            "requested": command.defaultCombo?.text as Any? ?? NSNull(),
            "conflict": blockedBy[command.id].flatMap(self.command)?.title as Any? ?? NSNull(),
            "customized": overrides[command.id] != nil,
        ]
    }

    private func deliver(owner: String, local: String) {
        ExtensionManager.shared.emit(owner, type: "shortcut", arguments: [local], to: .frontmost(frontWebView?()))
    }

    // MARK: Changing

    /// Gives `id` a new shortcut, or none when `combo` is nil. Throws when another command already has it.
    func setCombo(_ id: String, to combo: KeyCombo?) throws {
        guard let command = command(id), !command.isFixed else { return }
        if let combo {
            if let holderID = holders[combo], holderID != id, let other = self.command(holderID) {
                throw KeyCombo.Problem("\(combo.glyphs) is already used by \u{201C}\(other.title)\u{201D}.")
            }
            overrides[id] = combo == command.defaultCombo ? nil : combo.text
        } else {
            overrides[id] = command.defaultCombo == nil ? nil : ""
        }
        save()
        refresh()
    }

    func reset(_ id: String) {
        guard overrides.removeValue(forKey: id) != nil else { return }
        save()
        refresh()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        save()
        refresh()
    }

    private func save() {
        UserDefaults.standard.set(overrides, forKey: Self.defaultsKey)
    }

    // MARK: Menus

    /// A menu entry for a command, showing (and, as a fallback, answering to) its shortcut.
    func menuItem(for id: String) -> NSMenuItem? {
        guard let command = command(id) else { return nil }
        let combo = resolved[id]
        let item: NSMenuItem
        switch command.action {
        case .run:
            item = NSMenuItem(title: command.title, action: #selector(performFromMenu(_:)), keyEquivalent: combo?.menuKey ?? "")
            item.target = self
        case .responder(let selector):
            item = NSMenuItem(title: command.title, action: selector, keyEquivalent: combo?.menuKey ?? "")
        }
        item.keyEquivalentModifierMask = combo?.menuModifiers ?? []
        item.representedObject = id
        return item
    }

    @MainActor @objc private func performFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { perform(id) }
    }

    @MainActor func perform(_ id: String) {
        if case .run(let body)? = command(id)?.action { body() }
    }

    @MainActor @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = menuItem.representedObject as? String else { return true }
        return command(id)?.validate?(menuItem) ?? true
    }

    // MARK: Key presses

    /// While set, every key press goes here instead of running a command. Settings uses it to record a new shortcut.
    private(set) var keyCapture: (owner: String, handler: (NSEvent) -> Void)?

    func captureKeys(for owner: String, _ handler: @escaping (NSEvent) -> Void) {
        keyCapture = (owner, handler)
    }

    func stopCapturingKeys(for owner: String) {
        if keyCapture?.owner == owner { keyCapture = nil }
    }

    /// Offered every key press by `SatelliteApplication` before AppKit matches it against menu items (which can't
    /// tell Cmd+R from Shift+Cmd+R). Returns whether the key press was taken.
    @MainActor
    func intercept(_ event: NSEvent) -> Bool {
        if let capture = keyCapture {
            capture.handler(event)
            return true
        }
        return handle(event)
    }

    /// Runs the command whose shortcut `event` is, if it has one. Standard commands (Copy, Quit...) are left to the menu.
    @MainActor @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil, let pressed = try? KeyCombo(event: event) else { return false }
        var candidates = [pressed]
        // "+" is typed as Shift+"=", so Cmd+Shift+= also means the shortcut written Cmd+=.
        if pressed.key == "=", pressed.modifiers.contains(.shift),
           let plain = try? KeyCombo(key: "=", modifiers: pressed.modifiers.subtracting(.shift)) {
            candidates.append(plain)
        }
        for combo in candidates {
            guard let id = holders[combo] else { continue }
            guard case .run(let body)? = command(id)?.action else { return false }
            body()
            return true
        }
        return false
    }

    // MARK: Resolving

    /// Decides who gets which shortcut, then tells the menus and Settings.
    private func refresh() {
        var taken: [KeyCombo: String] = [:]
        var result: [String: KeyCombo] = [:]
        var blocked: [String: String] = [:]
        let all = commands

        func claim(_ command: ShortcutCommand, _ combo: KeyCombo) {
            if let holder = taken[combo] {
                blocked[command.id] = holder
            } else {
                taken[combo] = command.id
                result[command.id] = combo
            }
        }
        for command in all where command.isFixed {
            if let combo = command.defaultCombo { claim(command, combo) }
        }
        for command in all where !command.isFixed {
            if let text = overrides[command.id], !text.isEmpty, let combo = try? KeyCombo(parsing: text) { claim(command, combo) }
        }
        for command in all where !command.isFixed && overrides[command.id] == nil {
            if let combo = command.defaultCombo { claim(command, combo) }
        }

        resolved = result
        holders = taken
        blockedBy = blocked
        revision += 1
        scheduleNotify()
    }

    /// Several changes in one turn of the run loop produce one update.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [self] in
            notifyScheduled = false
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}
