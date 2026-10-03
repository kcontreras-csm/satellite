import AppKit
import WebKit

/// How the find bar matches. Remembered between launches and shared by every page.
struct FindOptions: Equatable {
    var regex = false
    var caseSensitive = false
    var wholeWord = false

    static let changed = Notification.Name("SatelliteFindOptionsChanged")
    private static let defaultsKeys = ["findUseRegex", "findMatchCase", "findWholeWord"]

    static var current: FindOptions = {
        let defaults = UserDefaults.standard
        return FindOptions(
            regex: defaults.bool(forKey: defaultsKeys[0]),
            caseSensitive: defaults.bool(forKey: defaultsKeys[1]),
            wholeWord: defaults.bool(forKey: defaultsKeys[2]))
    }() {
        didSet {
            guard current != oldValue else { return }
            let defaults = UserDefaults.standard
            defaults.set(current.regex, forKey: defaultsKeys[0])
            defaults.set(current.caseSensitive, forKey: defaultsKeys[1])
            defaults.set(current.wholeWord, forKey: defaultsKeys[2])
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// What the search engine in the page is given.
    var json: [String: Bool] { ["regex": regex, "caseSensitive": caseSensitive, "wholeWord": wholeWord] }

    /// Text that a regular expression matches literally.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if ".*+?^${}()|[]\\/".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// The find bar that floats over the top right of a page: type to find, Return or Shift+Return to step, Esc to close.
/// Every match on the page is highlighted and counted, in the page and its frames, with the options to match a
/// regular expression, the case, or whole words.
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    private weak var webView: WKWebView?
    private let finder: PageFinder
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let regexButton = NSButton()
    private let caseButton = NSButton()
    private let wordButton = NSButton()
    private var optionsObserver: NSObjectProtocol?

    /// Searches run one after another; a search that a newer one has replaced is skipped.
    private var chain: Task<Void, Never>?
    private var generation = 0
    private(set) var outcome = PageFinder.Outcome.cleared

    var text: String { field.stringValue }
    var statusText: String { status.stringValue }
    var isShowing: Bool { superview != nil }

    init(webView: WKWebView) {
        self.webView = webView
        finder = PageFinder(webView: webView)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Find in page"
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        field.font = .systemFont(ofSize: 13)

        func symbolButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            // The colour is part of the image: the bezel style would otherwise tint the glyph with the accent colour.
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = label
            return button
        }
        func optionButton(_ button: NSButton, _ title: String, _ action: Selector) {
            button.title = title
            button.target = self
            button.action = action
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        optionButton(regexButton, ".*", #selector(toggleRegex))
        optionButton(caseButton, "Aa", #selector(toggleCase))
        optionButton(wordButton, "ab", #selector(toggleWord))

        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [
            field,
            symbolButton("chevron.up", "Previous match", #selector(previousClicked)),
            symbolButton("chevron.down", "Next match", #selector(nextClicked)),
            symbolButton("xmark", "Close", #selector(doneClicked)),
        ])
        let bottom = NSStackView(views: [regexButton, caseButton, wordButton, status, symbolButton("ellipsis.circle", "More", #selector(showMenu(_:)))])
        for row in [top, bottom] { row.spacing = 5 }
        bottom.spacing = 6
        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 330),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])

        optionsObserver = NotificationCenter.default.addObserver(forName: FindOptions.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                self.syncOptions()
                self.runSearch()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let optionsObserver { NotificationCenter.default.removeObserver(optionsObserver) }
    }

    // MARK: Showing

    /// Shows the bar over the page and searches. `prefill` is the text selected on the page, if any.
    func show(prefill: String?, focus: Bool = true) {
        guard let webView else { return }
        if superview == nil {
            webView.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: webView.topAnchor, constant: 10),
                trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -16),
                leadingAnchor.constraint(greaterThanOrEqualTo: webView.leadingAnchor, constant: 8),
            ])
        }
        syncOptions()
        if let prefill, !prefill.isEmpty { field.stringValue = FindOptions.current.regex ? FindOptions.escaped(prefill) : prefill }
        if focus {
            // The field has to have its size before it is edited: a text editor made for a field that is still 0 wide
            // stays offset when the field grows, and the text (and placeholder) is drawn outside of it.
            webView.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()
            webView.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        runSearch()
    }

    /// Closes the bar and gives the page the keyboard back. The current match stays selected, so it can be copied.
    func hide() {
        guard isShowing else { return }
        removeFromSuperview()
        generation += 1
        status.stringValue = ""
        enqueue { [finder] in
            await finder.selectCurrent()
            _ = await finder.clear()
        }
        webView?.window?.makeFirstResponder(webView)
    }

    /// The page changed under the bar (a new page loaded), so look again.
    func pageDidChange() {
        if isShowing { runSearch() }
    }

    /// Steps to the next or previous match. With the bar closed this shows the bar on the match nearest to you.
    func find(forward: Bool) {
        guard !field.stringValue.isEmpty else { return }
        guard isShowing else { return show(prefill: nil, focus: false) }
        enqueue { [weak self] in
            guard let self else { return }
            self.display(await self.finder.step(forward: forward))
        }
    }

    // MARK: Searching

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func runSearch() {
        generation += 1
        let mine = generation
        let query = field.stringValue
        let options = FindOptions.current
        enqueue { [weak self] in
            guard let self, mine == self.generation else { return }
            self.display(await self.finder.search(query, options: options))
        }
    }

    private func display(_ outcome: PageFinder.Outcome) {
        self.outcome = outcome
        var message = ""
        var color = NSColor.secondaryLabelColor
        var tooltip: String?
        switch outcome {
        case .cleared: break
        case .none: message = "No results"
        case .matches(let index, let total, let truncated): message = "\(index) of \(total)\(truncated ? "+" : "")"
        case .invalid(let reason):
            message = "Invalid: \(reason)"
            tooltip = reason
            color = .systemRed
        case .unavailable: message = "Can\u{2019}t search this page"
        }
        status.stringValue = message
        status.textColor = color
        status.toolTip = tooltip
        field.textColor = tooltip == nil ? .labelColor : .systemRed
    }

    private func syncOptions() {
        let options = FindOptions.current
        regexButton.state = options.regex ? .on : .off
        caseButton.state = options.caseSensitive ? .on : .off
        wordButton.state = options.wholeWord ? .on : .off
        func tip(_ title: String, _ id: String) -> String {
            title + (ShortcutRegistry.shared.combo(for: id).map { " (\($0.glyphs))" } ?? "")
        }
        regexButton.toolTip = tip("Use Regular Expression", "find.regex")
        caseButton.toolTip = tip("Match Case", "find.caseSensitive")
        wordButton.toolTip = tip("Match Whole Word", "find.wholeWord")
        field.placeholderString = options.regex ? "Find (regex)" : "Find in page"
    }

    // MARK: Events

    func controlTextDidChange(_ notification: Notification) {
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    /// The clear button of the field.
    @objc private func fieldAction() {
        if field.stringValue.isEmpty { runSearch() }
    }

    @objc private func toggleRegex() { FindOptions.current.regex = regexButton.state == .on }
    @objc private func toggleCase() { FindOptions.current.caseSensitive = caseButton.state == .on }
    @objc private func toggleWord() { FindOptions.current.wholeWord = wordButton.state == .on }
    @objc private func nextClicked() { find(forward: true) }
    @objc private func previousClicked() { find(forward: false) }
    @objc private func doneClicked() { hide() }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy All Matches", action: #selector(copyMatches), keyEquivalent: "")
        copy.target = self
        if case .matches = outcome {} else { copy.isEnabled = false }
        menu.addItem(copy)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Puts every match on the clipboard, one per line.
    @objc private func copyMatches() {
        enqueue { [weak self] in
            guard let self else { return }
            let matches = await self.finder.allMatches()
            guard !matches.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(matches.joined(separator: "\n"), forType: .string)
            Toast.show("Copied \(matches.count) match\(matches.count == 1 ? "" : "es")", in: self.webView?.window)
        }
    }
}
