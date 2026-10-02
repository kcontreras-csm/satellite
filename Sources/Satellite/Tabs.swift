import AppKit
import WebKit

/// The tabs of one sidebar app. The first tab is the app itself and stays; the others are opened by links and
/// `window.open` and can be closed.
@MainActor
final class TabGroup {
    private(set) var tabs: [WebPane]
    private(set) var selectedIndex = 0
    /// Also open links to other sites as tabs, instead of sending them to the default browser.
    var opensAllLinksInTabs: Bool
    /// Called whenever the tabs or the selected tab change.
    var onChange: (() -> Void)?

    var home: WebPane { tabs[0] }
    var current: WebPane { tabs[min(selectedIndex, tabs.count - 1)] }
    var hasClosableTab: Bool { selectedIndex > 0 }

    init(name: String, url: URL, opensAllLinksInTabs: Bool) {
        let home = WebPane(name: name, url: url)
        tabs = [home]
        self.opensAllLinksInTabs = opensAllLinksInTabs
        home.tabHost = self
    }

    /// A new tab for a page that asked for a new window. WebKit loads the request into the returned pane's view.
    func openTab(configuration: WKWebViewConfiguration) -> WebPane {
        let pane = WebPane(name: "New tab", url: nil, configuration: configuration)
        pane.tabHost = self
        pane.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane)
        }
        tabs.append(pane)
        selectedIndex = tabs.count - 1
        onChange?()
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onChange?()
    }

    func selectNext() { if tabs.count > 1 { select((selectedIndex + 1) % tabs.count) } }
    func selectPrevious() { if tabs.count > 1 { select((selectedIndex - 1 + tabs.count) % tabs.count) } }

    /// Closes the selected tab unless it is the app's own. Returns whether a tab was closed.
    @discardableResult
    func closeCurrent() -> Bool {
        guard hasClosableTab else { return false }
        close(tabs[selectedIndex])
        return true
    }

    func close(at index: Int) {
        guard index > 0, tabs.indices.contains(index) else { return }
        close(tabs[index])
    }

    func close(_ pane: WebPane) {
        guard let index = tabs.firstIndex(where: { $0 === pane }), index > 0 else { return }
        tabs.remove(at: index)
        pane.teardown()
        if selectedIndex >= index { selectedIndex = max(0, selectedIndex - 1) }
        onChange?()
    }

    func reloadAll() { tabs.forEach { $0.reloadIfLoaded() } }

    func teardown() {
        tabs.forEach { $0.teardown() }
    }
}

// MARK: - Tab bar

/// One tab: a title and (for closable tabs) a close button.
final class TabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    var isSelected = false {
        didSet { refreshAppearance() }
    }

    init(title: String, selected: Bool, closable: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = !closable
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: closable ? closeButton.leadingAnchor : trailingAnchor, constant: closable ? -4 : -10),
        ])
        isSelected = selected
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setTitle(_ title: String) { label.stringValue = title }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return !closeButton.isHidden && closeButton.frame.contains(convert(point, from: superview)) ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() { onClose?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        }
    }
}

/// A strip of tabs above the web content; only visible when an app has more than one.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()
    private var buttons: [TabButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(titles: [String], selected: Int) {
        buttons.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons = titles.enumerated().map { index, title in
            let button = TabButton(title: title, selected: index == selected, closable: index > 0)
            button.onSelect = { [weak self] in self?.onSelect?(index) }
            button.onClose = { [weak self] in self?.onClose?(index) }
            return button
        }
        buttons.forEach(stack.addArrangedSubview)
    }

    /// Updates labels in place (page titles arrive after the tab exists).
    func updateTitles(_ titles: [String]) {
        for (button, title) in zip(buttons, titles) { button.setTitle(title) }
    }
}
