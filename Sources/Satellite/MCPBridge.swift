import AppKit
import Darwin

/// Listens on a local Unix socket so `MCPStdioServer` — a tiny process an agent's MCP config spawns, such as Claude
/// Code running in a Terminal assistant — can ask for the page open in Satellite's apps panel.
///
/// Each asking agent (identified by its Terminal pane id, passed down as an environment variable when the pane
/// starts) is confirmed once, the same way "Send to Assistant" confirms an assistant before a page reaches it:
/// pages can hold customer data, and not every agent run outside Satellite is approved for it. "Don't ask again"
/// remembers it exactly like that confirmation does, reusing the same trust store.
@MainActor
final class MCPBridge {
    static let shared = MCPBridge()
    weak var mainController: MainWindowController?
    var trust: AssistantTrust = .shared

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "satellite.mcp.accept")

    func start() {
        stop()
        let path = MCPSocket.path
        unlink(path)
        guard var addr = MCPSocket.address(for: path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let size = MemoryLayout<sockaddr_un>.size
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }
        chmod(path, 0o600)   // this user only; the socket carries page content and a pane id
        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(MCPSocket.path)
    }

    private nonisolated func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }   // the listening socket was closed in stop()
            guard let request = MCPSocket.receiveLine(from: client) else { close(client); continue }
            Task { @MainActor [self] in
                let response = await self.handle(request)
                MCPSocket.sendLine(response, to: client)
                close(client)
            }
        }
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        guard let controller = mainController else {
            return ["ok": false, "error": "Satellite\u{2019}s window isn\u{2019}t available yet."]
        }
        let paneID = request["paneId"] as? String ?? ""
        let label = AppsModel.shared.config.assistants.first(where: { $0.id == paneID })?.name ?? "A command-line agent"
        let trustID = "mcp:\(paneID)"
        if !trust.isTrusted(trustID) {
            let answer = await Self.confirm(label: label, window: controller.window)
            guard answer.send else { return ["ok": false, "error": "The user didn\u{2019}t allow \(label) to read this page."] }
            if answer.remember { trust.set(trustID, trusted: true) }
        }
        guard let pane = controller.currentWebsitePane, pane.didCreateView, pane.webView.url != nil else {
            return ["ok": false, "error": "There is no page open in Satellite to read."]
        }
        do {
            let text = try await PageSnapshot.capture(pane.webView, options: .init(forAssistant: true))
            return ["ok": true, "text": text]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private static func confirm(label: String, window: NSWindow?) async -> AssistantSender.Answer {
        let alert = NSAlert()
        alert.messageText = "Let \(label) read this page?"
        alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to read the page open in the apps panel \u{2014} its URL, title and visible content. Pages can hold customer data, so only allow agents approved for it.\n\nPage text: \(SnapshotTextMode.current.summary) (change this in Settings > General)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t ask again for \(label)"
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let send = response == .alertFirstButtonReturn
        return AssistantSender.Answer(send: send, remember: send && alert.suppressionButton?.state == .on)
    }
}
