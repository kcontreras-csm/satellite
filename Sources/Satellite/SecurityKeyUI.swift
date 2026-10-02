import AppKit
import SwiftUI

/// The window shown while a site waits for a security key, plus the PIN and account-picker dialogs.
@MainActor
final class SecurityKeyPrompt: ObservableObject {
    static let shared = SecurityKeyPrompt()

    enum State {
        case insert
        case touch
        case wrongKey
    }

    @Published var state: State = .insert
    @Published private(set) var site = ""
    @Published private(set) var verb = ""

    private var panel: NSPanel?
    private var cancelAction: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    /// Shows the prompt. `cancel` runs if the user presses Cancel or closes the window.
    func begin(site: String, verb: String, over window: NSWindow?, cancel: @escaping () -> Void) {
        end()
        self.site = site
        self.verb = verb
        state = .insert
        cancelAction = cancel

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 250),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Security Key"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SecurityKeyPromptView(prompt: self) { [weak self] in self?.userCancelled() })
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 190, y: frame.midY - 125))
        } else {
            panel.center()
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userCancelled() }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func end() {
        cancelAction = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func userCancelled() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }

    // MARK: Dialogs

    /// Asks for the key's PIN; nil if the user cancels.
    func askPIN(site: String, retries: Int?, wrong: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = wrong ? "Wrong PIN" : "Enter your security key PIN"
        var detail = "\(site) needs the PIN of your security key."
        if let retries { detail += " You have \(retries) attempt\(retries == 1 ? "" : "s") left before the key locks." }
        alert.informativeText = detail
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let pin = field.stringValue
        return response == .alertFirstButtonReturn && !pin.isEmpty ? pin : nil
    }

    /// Lets the user pick which account on the key to sign in with.
    func choose(site: String, from assertions: [Assertion]) async -> Assertion? {
        let alert = NSAlert()
        alert.messageText = "Choose an account"
        alert.informativeText = "Which account do you want to use for \(site)?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for (index, assertion) in assertions.enumerated() {
            popup.addItem(withTitle: assertion.userDisplayName ?? assertion.userName ?? "Account \(index + 1)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return assertions[popup.indexOfSelectedItem]
    }
}

struct SecurityKeyPromptView: View {
    @ObservedObject var prompt: SecurityKeyPrompt
    let cancel: () -> Void

    private var icon: String {
        switch prompt.state {
        case .insert: return "cable.connector"
        case .touch: return "key.horizontal.fill"
        case .wrongKey: return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch prompt.state {
        case .insert: return "Insert your security key"
        case .touch: return "Touch your security key"
        case .wrongKey: return "Try another security key"
        }
    }

    private var detail: String {
        switch prompt.state {
        case .insert: return "Plug it into a USB port. Satellite supports USB security keys (FIDO2 and U2F)."
        case .touch: return "Touch the button or gold contact on the key when it blinks."
        case .wrongKey: return "This key isn\u{2019}t registered for this site. Insert or touch a different one."
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(prompt.state == .wrongKey ? Color.orange : Color.accentColor)
                .symbolEffect(.pulse, isActive: prompt.state == .touch)
            Text(title).font(.headline)
            Text("to \(prompt.verb) \(prompt.site)").foregroundStyle(.secondary)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 380, height: 250)
    }
}
