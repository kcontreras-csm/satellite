import AppKit

/// A sidebar button: SF Symbol above a small label, both centered in a fixed-size tile,
/// with a rounded highlight when selected and an optional badge.
final class RailButton: NSControl {
    static let size = NSSize(width: 64, height: 52)

    var isSelected = false {
        didSet { refreshAppearance() }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    init(title: String, symbol: String, tooltip: String, badge: String?) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgePill.wantsLayer = true
        badgePill.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgePill.layer?.cornerRadius = 7
        badgePill.translatesAutoresizingMaskIntoConstraints = false
        badgePill.addSubview(badgeLabel)
        addSubview(badgePill)

        // Every icon gets the same slot, so differently shaped symbols line up.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            badgeLabel.leadingAnchor.constraint(equalTo: badgePill.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgePill.trailingAnchor, constant: -4),
            badgeLabel.topAnchor.constraint(equalTo: badgePill.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgePill.bottomAnchor, constant: -1),
            badgePill.widthAnchor.constraint(greaterThanOrEqualTo: badgePill.heightAnchor),
            badgePill.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -8),
            badgePill.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -5),
        ])

        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        configure(title: title, symbol: symbol, tooltip: tooltip, badge: badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, symbol: String, tooltip: String, badge: String?) {
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        iconView.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                          ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil))?
            .withSymbolConfiguration(config)
        label.stringValue = title
        toolTip = tooltip
        badgeLabel.stringValue = badge ?? ""
        badgePill.isHidden = badge == nil
        setAccessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        refreshAppearance()
    }

    // The icon and label are decoration; the whole tile is the click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        alphaValue = 0.6
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            alphaValue = inside ? 0.6 : 1
            if next.type == .leftMouseUp {
                alphaValue = 1
                if inside { sendAction(action, to: target) }
                return
            }
        }
        alphaValue = 1
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        let tint: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        iconView.contentTintColor = tint
        label.textColor = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }
}

final class RailViewController: NSViewController {
    var onSelect: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?

    private var items: [SidebarItem] = []
    private var buttons: [RailButton] = []
    private var selectedID: String?
    private let stack = NSStackView()

    override func loadView() {
        let root = NSView()

        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let settings = RailButton(title: "Settings", symbol: "gearshape", tooltip: "Settings  \u{2318},", badge: nil)
        settings.target = self
        settings.action = #selector(settingsClicked)

        root.addSubview(stack)
        root.addSubview(settings)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            settings.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            settings.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
        view = root
    }

    /// Shows `newItems`. When only names, icons or badges changed the existing buttons are updated in place.
    func setItems(_ newItems: [SidebarItem]) {
        if newItems.map(\.id) == items.map(\.id), buttons.count == newItems.count {
            for (index, item) in newItems.enumerated() { configure(buttons[index], item: item, index: index) }
        } else {
            for button in buttons {
                stack.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            buttons = newItems.enumerated().map { index, item in
                let button = RailButton(title: item.name, symbol: item.symbol, tooltip: "", badge: item.badge)
                button.target = self
                button.action = #selector(appClicked(_:))
                configure(button, item: item, index: index)
                return button
            }
            buttons.forEach(stack.addArrangedSubview)
        }
        items = newItems
        applySelection()
    }

    func setSelected(_ id: String?) {
        selectedID = id
        applySelection()
    }

    private func configure(_ button: RailButton, item: SidebarItem, index: Int) {
        button.tag = index
        var tooltip = item.name
        if index < 9 { tooltip += "  \u{2318}\(index + 1)" }
        if let owner = item.owner { tooltip += "\nAdded by the \(owner) extension" }
        button.configure(title: item.name, symbol: item.symbol, tooltip: tooltip, badge: item.badge)
    }

    private func applySelection() {
        for (index, button) in buttons.enumerated() { button.isSelected = items.indices.contains(index) && items[index].id == selectedID }
    }

    @objc private func appClicked(_ sender: NSControl) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect?(items[sender.tag].id)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }
}
