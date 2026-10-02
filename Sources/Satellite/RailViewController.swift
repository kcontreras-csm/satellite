import AppKit

/// A borderless sidebar button: SF Symbol above a small label, with a rounded highlight when selected.
final class RailButton: NSButton {
    var isSelected = false {
        didSet { refreshAppearance() }
    }

    init(title: String, symbol: String, tooltip: String) {
        super.init(frame: .zero)
        self.title = title
        toolTip = tooltip
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 10, weight: .medium)
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        image = (NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                 ?? NSImage(systemSymbolName: "globe", accessibilityDescription: title))?
            .withSymbolConfiguration(config)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 60).isActive = true
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
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
        settings.translatesAutoresizingMaskIntoConstraints = false

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

    @objc private func appClicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }
}
