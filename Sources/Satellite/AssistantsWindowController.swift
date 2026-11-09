import AppKit

/// The separate window the assistants panel moves into when it is docked out of the main window. It only hosts
/// the panel's view controller (the web views and terminals live in it and keep running as it moves), so
/// `MainWindowController` owns the dock state and decides when to put the panel in or take it out.
final class AssistantsWindowController: NSWindowController, NSWindowDelegate {
    /// The red close button (and Cmd+W) asks to dock the panel back instead of destroying the window.
    var onCloseRequest: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Assistants"
        window.minSize = NSSize(width: 340, height: 400)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        // Restore where it was last; the first time (or when that screen is gone) it opens beside the main window.
        if !window.setFrameUsingName("SatelliteAssistantsWindow") { window.center() }
        window.setFrameAutosaveName("SatelliteAssistantsWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Puts the panel in this window. It keeps the size the user last gave the window rather than the panel's.
    func host(_ controller: NSViewController) {
        let frame = window?.frame
        window?.contentViewController = controller
        if let frame { window?.setFrame(frame, display: false) }
        keepOnScreen()
    }

    /// Takes the panel out, so it can go back into the main window.
    func release() {
        window?.contentViewController = nil
    }

    var isShown: Bool { window?.isVisible == true }

    /// Shows the window; `activate` makes it the one that takes keystrokes.
    func present(activate: Bool) {
        keepOnScreen()
        if activate {
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }

    func hide() { window?.orderOut(nil) }

    /// A saved position on a screen that is no longer there would leave the window out of reach.
    private func keepOnScreen() {
        guard let window else { return }
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !visible { window.center() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?()
        return false
    }
}
