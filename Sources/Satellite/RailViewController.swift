import AppKit

/// A sidebar button: SF Symbol above a small label, both centered in a fixed-size tile,
/// with a rounded highlight when selected.
final class RailButton: NSControl {
    static let size = NSSize(width: 64, height: 52)

    var isSelected = false {
        didSet { refreshAppearance() }
    }

    private let iconView = NSImageView()
    private let label: NSTextField

    init(title: String, symbol: String, tooltip: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        iconView.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                          ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil))?
            .withSymbolConfiguration(config)
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

        // Every icon gets the same slot, so differently shaped symbols line up.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])

        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

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
    var onSelect: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let apps: [WebApp]
    private var buttons: [RailButton] = []

    init(apps: [WebApp]) {
        self.apps = apps
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, app) in apps.enumerated() {
            let button = RailButton(title: app.name, symbol: app.symbol, tooltip: "\(app.name)  \u{2318}\(index + 1)")
            button.tag = index
            button.target = self
            button.action = #selector(appClicked(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
        }

        let settings = RailButton(title: "Settings", symbol: "gearshape", tooltip: "Settings  \u{2318},")
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

    func setSelected(_ index: Int) {
        for (i, button) in buttons.enumerated() { button.isSelected = (i == index) }
    }

    @objc private func appClicked(_ sender: NSControl) {
        onSelect?(sender.tag)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }
}
