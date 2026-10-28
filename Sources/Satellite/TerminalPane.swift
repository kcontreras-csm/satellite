import AppKit
import SwiftTerm
import SwiftUI

/// A terminal in the assistants panel: your login shell (or a configured command) in a native terminal view.
///
/// Nothing on a web page can reach it: there is no bridge from pages or extensions, so only you type into it.
/// Satellite itself only pastes into it when you send a selection or page there (Send to Assistant), and only as a
/// bracketed paste, which the program receives as text rather than as keys it would run.
@MainActor
final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {
    let id: String
    private(set) var name: String
    private(set) var config: TerminalConfig
    let view = SatelliteTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    /// What the panel shows: the terminal with its padding around it.
    let host = TerminalHostView()
    private var insets: [NSLayoutConstraint] = []
    private(set) var isRunning = false
    private(set) var hasStarted = false

    static let defaultFontSize: CGFloat = 13
    private static let fontSizeKey = "terminalFontSize"

    init(id: String, name: String, config: TerminalConfig) {
        self.id = id
        self.name = name
        self.config = config
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.processDelegate = self
        view.pane = self
        host.terminal = view
        host.addSubview(view)
        insets = [
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(insets)
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        view.font = NSFont.monospacedSystemFont(ofSize: saved > 0 ? saved : Self.defaultFontSize, weight: .regular)
        show(theme)
        applyPadding()
    }

    /// A changed theme or padding shows at once; a changed command or folder applies the next time the session starts.
    func update(name: String, config: TerminalConfig) {
        self.name = name
        let themeChanged = config.theme != self.config.theme
        let paddingChanged = config.effectivePadding != self.config.effectivePadding
        self.config = config
        if themeChanged && themePicker == nil { show(theme) }
        if paddingChanged { applyPadding() }
    }

    /// The padding in points: `padding` characters, each as wide as one in the terminal's font now.
    var paddingPoints: CGFloat { CGFloat(config.effectivePadding) * Self.characterWidth(view.font) }

    private func applyPadding() {
        let points = paddingPoints.rounded()
        for inset in insets { inset.constant = points }
    }

    /// The advance of one character in a monospaced font.
    nonisolated static func characterWidth(_ font: NSFont) -> CGFloat {
        ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    func startIfNeeded() {
        if !hasStarted { start() }
    }

    func start() {
        let launch = Self.launch(for: config, id: id)
        if hasStarted { view.softReset() }   // modes the last program left on (mouse, alternate screen...) shouldn't stick
        view.startProcess(executable: launch.executable, args: launch.args, environment: launch.environment,
                          execName: launch.execName, currentDirectory: launch.directory)
        hasStarted = true
        isRunning = true
    }

    func teardown() {
        if isRunning { view.terminate() }
        isRunning = false
        host.removeFromSuperview()
    }

    // MARK: Pasting

    enum PasteOutcome: Equatable {
        case pasted
        case notRunning
        /// The program in the terminal hasn't turned on bracketed paste, so a line break in the text would act as
        /// Return and run what came before it.
        case unsafe
    }

    /// Puts `text` at the prompt without pressing Return.
    func paste(_ text: String) -> PasteOutcome {
        guard isRunning else { return .notRunning }
        guard view.terminalContentSnapshot(region: .viewport)?.inputState.bracketedPasteMode == true else { return .unsafe }
        view.pasteText(text)
        return .pasted
    }

    // MARK: Theme

    /// The saved theme; nil follows the system's light or dark text colors.
    var theme: TerminalTheme? { TerminalTheme.named(config.theme) }

    private var themePicker: NSPopover?
    /// What the terminal shows now: the saved theme, or one being previewed in the theme list.
    private(set) var shownTheme: TerminalTheme?

    private func show(_ theme: TerminalTheme?) {
        shownTheme = theme
        view.apply(theme)
        host.fill = theme?.background.nsColor ?? .textBackgroundColor
    }

    /// Light or dark mode changed: System colors are resolved again (a Gogh theme stays as it is).
    func appearanceChanged() {
        if shownTheme == nil { view.apply(nil) }
    }

    /// Opens the theme list next to `rect` (in the terminal view). Picking a theme shows it at once; whatever is shown
    /// when the list closes is kept, in config.json, like the terminal's other settings.
    func showThemePicker(at rect: NSRect? = nil) {
        if let themePicker, themePicker.isShown { return }
        let original = theme
        var chosen = original
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TerminalThemePicker(
            original: original?.name,
            preview: { [weak self] in chosen = $0; self?.show($0) },
            done: { [weak popover] in popover?.performClose(nil) }))
        popover.delegate = ThemePickerCloser.shared
        ThemePickerCloser.shared.onClose[ObjectIdentifier(popover)] = { [weak self] in
            guard let self else { return }
            self.themePicker = nil
            if chosen?.name != original?.name { self.saveTheme(chosen) }
        }
        themePicker = popover
        let anchor = rect ?? NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 8, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// Keeps `theme` for this terminal in config.json, so Settings and the next launch see it, and shows it.
    func saveTheme(_ theme: TerminalTheme?) {
        show(theme)
        config.theme = theme?.name
        guard var app = AppsModel.shared.config.assistants.first(where: { $0.id == id }), app.terminal != nil else { return }
        app.terminal?.theme = theme?.name
        AppsModel.shared.save(app, in: .assistants)
    }

    // MARK: Appearance

    func zoom(_ change: ZoomChange) -> CGFloat {
        let current = view.font.pointSize
        let size: CGFloat
        switch change {
        case .larger: size = min(current + 1, 36)
        case .smaller: size = max(current - 1, 8)
        case .reset: size = Self.defaultFontSize
        }
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey)
        applyPadding()   // it is counted in characters, so it grows and shrinks with the text
        return size
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        let status = exitCode.map { $0 == 0 ? "" : " (exit status \($0))" } ?? ""
        view.feed(text: "\r\n\u{1B}[2m[Session ended\(status). Press Return to start a new one.]\u{1B}[0m\r\n")
    }

    // MARK: Launching

    struct Launch: Equatable {
        var executable: String
        var args: [String]
        var execName: String
        var environment: [String]
        var directory: String
    }

    /// How to start `config`: always through the user's login shell, interactive, so PATH and everything else from
    /// their shell profile apply (an app opened from the Dock gets a bare PATH, where `claude` and Homebrew tools
    /// aren't found). A command runs in that shell, which then stays open as an interactive shell.
    nonisolated static func launch(for config: TerminalConfig, id: String = "", shell: String = userShell(), home: String = NSHomeDirectory(),
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Launch {
        let shellName = (shell as NSString).lastPathComponent
        var args: [String] = []
        if let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            args = ["-l", "-i", "-c", "\(command); exec \(quoted(shell)) -l"]
        }

        var env = environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Satellite"
        env["TERM_PROGRAM_VERSION"] = AppInfo.version.description
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["SHELL"] = shell
        // Lets an MCP config in this terminal (e.g. Claude Code's) spawn `satellite --mcp-stdio` and have it
        // identify which pane is asking, so Satellite's "read the page" confirmation is remembered per agent.
        if !id.isEmpty { env["SATELLITE_MCP_PANE_ID"] = id }
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "VSCODE_INJECTION", "__CFBundleIdentifier"] { env.removeValue(forKey: key) }

        return Launch(
            executable: shell,
            args: args,
            execName: "-" + shellName,   // a leading "-" in argv[0] makes it a login shell, as Terminal does
            environment: env.map { "\($0.key)=\($0.value)" }.sorted(),
            directory: directory(config.directory, home: home))
    }

    /// The account's login shell, as Terminal uses it.
    nonisolated static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, let path = String(validatingUTF8: shell),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    /// The folder to start in: "~" and "~/x" are under home; anything that isn't an existing folder falls back to home.
    nonisolated static func directory(_ text: String?, home: String) -> String {
        guard var path = text?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return home }
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? path : home
    }

    nonisolated static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The terminal view, with what Satellite adds: Return restarts an ended session, Paste and Match Style is an ordinary
/// paste (a terminal only takes text anyway), System colors follow light and dark mode, and a right-click menu.
final class SatelliteTerminalView: LocalProcessTerminalView {
    weak var pane: TerminalPane?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let pane, !pane.isRunning {
            if data.contains(0x0D) { pane.start() }
            return
        }
        super.send(source: source, data: data)
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        paste(sender as Any)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pane?.appearanceChanged()
    }

    /// Right-click (unless the program in the terminal has asked for mouse clicks, which then go to it).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let location = convert(event.locationInWindow, from: nil)
        func item(_ title: String, _ action: Selector) {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
        }
        item("Copy", #selector(SatelliteTerminalView.copy(_:)))
        item("Paste", #selector(SatelliteTerminalView.paste(_:)))
        item("Select All", #selector(SatelliteTerminalView.selectAll(_:)))
        menu.addItem(.separator())

        let themes = NSMenu()
        let current = pane?.theme
        let system = ClosureMenuItem(title: "System") { [weak self] in self?.pane?.saveTheme(nil) }
        system.state = current == nil ? .on : .off
        themes.addItem(system)
        if let current {
            let shown = ClosureMenuItem(title: current.name) {}
            shown.state = .on
            themes.addItem(shown)
        }
        themes.addItem(.separator())
        themes.addItem(ClosureMenuItem(title: "Choose Theme\u{2026}") { [weak self] in
            self?.pane?.showThemePicker(at: NSRect(x: location.x, y: location.y, width: 1, height: 1))
        })
        let themeItem = menu.addItem(withTitle: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        return menu
    }
}

/// Holds a terminal with its padding around it, filled with the terminal's background so the padding looks like part
/// of it. A click in the padding goes to the terminal.
final class TerminalHostView: NSView {
    weak var terminal: NSView?
    /// The terminal's background: a theme's, or the dynamic system one (resolved for light or dark when drawn).
    var fill: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let terminal { window?.makeFirstResponder(terminal) }
    }
}

/// Tells each theme list's terminal when the list closed (NSPopover's delegate is weak, so this one lives on).
@MainActor
final class ThemePickerCloser: NSObject, NSPopoverDelegate {
    static let shared = ThemePickerCloser()
    var onClose: [ObjectIdentifier: () -> Void] = [:]

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        onClose.removeValue(forKey: ObjectIdentifier(popover))?()
    }
}
