import AppKit
import WebKit

/// Center area: one lazily loaded web view per app, only the selected one visible.
final class ContentViewController: NSViewController {
    let panes: [WebPane]
    private(set) var selectedIndex = 0

    init(apps: [WebApp]) {
        panes = apps.map { WebPane(name: $0.name, url: $0.url) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView()
    }

    var selectedPane: WebPane { panes[selectedIndex] }

    func select(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        selectedIndex = index
        let pane = panes[index]
        if pane.webView.superview == nil {
            view.addSubview(pane.webView)
            NSLayoutConstraint.activate([
                pane.webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                pane.webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pane.webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pane.webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        for other in panes where other.webView.superview != nil { other.webView.isHidden = (other !== pane) }
        pane.loadIfNeeded()
        view.window?.makeFirstResponder(pane.webView)
    }

    func reloadAll() {
        panes.forEach { $0.reloadIfLoaded() }
    }
}

/// Right panel: a segmented switcher over lazily loaded assistant web views.
final class AssistantsViewController: NSViewController {
    let panes: [WebPane]
    private(set) var selectedIndex = 0
    private let segmented: NSSegmentedControl
    private let container = NSView()
    private var isLoaded = false

    init(assistants: [WebApp]) {
        panes = assistants.map { WebPane(name: $0.name, url: $0.url) }
        segmented = NSSegmentedControl(
            labels: assistants.map(\.name), trackingMode: .selectOne, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var selectedPane: WebPane? { panes.indices.contains(selectedIndex) ? panes[selectedIndex] : nil }

    override func loadView() {
        let root = NSView()
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.segmentDistribution = .fillEqually
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(segmented)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    // Nothing is loaded until the panel is actually shown.
    override func viewDidAppear() {
        super.viewDidAppear()
        if !isLoaded {
            isLoaded = true
            select(selectedIndex)
        }
    }

    func select(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        selectedIndex = index
        segmented.selectedSegment = index
        guard isLoaded else { return }
        let pane = panes[index]
        if pane.webView.superview == nil {
            container.addSubview(pane.webView)
            NSLayoutConstraint.activate([
                pane.webView.topAnchor.constraint(equalTo: container.topAnchor),
                pane.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        for other in panes where other.webView.superview != nil { other.webView.isHidden = (other !== pane) }
        pane.loadIfNeeded()
        view.window?.makeFirstResponder(pane.webView)
    }

    func reloadAll() {
        panes.forEach { $0.reloadIfLoaded() }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        select(sender.selectedSegment)
    }
}
