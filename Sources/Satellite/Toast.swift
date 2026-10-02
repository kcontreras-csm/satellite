import AppKit

/// A short message that floats over the bottom of a window and fades away by itself.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var timer: Timer?

    /// `duration` of nil keeps the message until the next `show` or `dismiss` (for "working..." messages).
    static func show(_ text: String, in window: NSWindow?, duration: TimeInterval? = 2.5) {
        dismiss(animated: false)
        guard let window else { return }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])

        let size = NSSize(width: label.intrinsicContentSize.width + 32, height: label.intrinsicContentSize.height + 20)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = background
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.minY + 36))
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { dismiss(animated: true) }
            }
        }
    }

    static func dismiss(animated: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        self.panel = nil
        let remove = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: remove)
        } else {
            remove()
        }
    }
}
