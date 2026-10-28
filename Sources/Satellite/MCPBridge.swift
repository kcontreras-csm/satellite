import AppKit
import Darwin

/// Listens on a local Unix socket so `MCPStdioServer` — a tiny process an agent's MCP config spawns, such as Claude
/// Code running in a Terminal assistant — can read, click and type on the page open in Satellite's apps panel, or
/// read every page in one of its tab groups (`TabCluster`) at once. Reading (not writing) can also target any
/// other open app by name or id, whether or not it's the one shown now: a background page's web view keeps
/// running regardless of visibility, so there's no need to switch to it just to read it.
///
/// Each asking agent (identified by its Terminal pane id, passed down as an environment variable when the pane
/// starts) is confirmed once, the same way "Send to Assistant" confirms an assistant before a page reaches it:
/// pages can hold customer data, and not every agent run outside Satellite is approved for it. Reading and writing
/// are trusted separately — allowing one never silently allows the other — and "Don't ask again" remembers each
/// the same way that confirmation does, reusing the same trust store. There is no further gate per click or
/// keystroke once an agent is trusted to write: that single confirmation is the control, so its wording says
/// plainly what it grants.
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
        chmod(path, 0o600)   // this user only; the socket carries page content, page actions and a pane id
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
        let action = request["action"] as? String ?? "read"
        let paneID = request["paneId"] as? String ?? ""
        let label = AppsModel.shared.config.assistants.first(where: { $0.id == paneID })?.name ?? "A command-line agent"
        let kind: Kind = ["click", "type"].contains(action) ? .write : .read
        let trustID = "\(kind.trustPrefix):\(paneID)"
        if !trust.isTrusted(trustID) {
            let answer = await Self.confirm(kind, label: label, window: controller.window)
            guard answer.send else { return ["ok": false, "error": "The user didn\u{2019}t allow \(label) to \(kind.declinedVerb) this page."] }
            if answer.remember { trust.set(trustID, trusted: true) }
        }
        if action == "list" {
            let apps = controller.allWebsiteApps()
            let lines = apps.map { app -> String in
                if let title = app.title, let url = app.url { return "- \(app.name) (app: \u{201C}\(app.id)\u{201D}) \u{2014} \u{201C}\(title)\u{201D} \(url)" }
                return "- \(app.name) (app: \u{201C}\(app.id)\u{201D}) \u{2014} not opened yet"
            }
            let text = "Apps open in Satellite. Pass one\u{2019}s name or id as `app` to read_active_page or read_tab_group to read it without switching to it:\n" + lines.joined(separator: "\n")
            return ["ok": true, "text": text]
        }

        // click/type always act on the app shown now — reading elsewhere is one thing, acting on a page the user
        // isn't even looking at is another, so "app" only applies to the read actions below.
        let targetPane: WebPane?
        if ["read", "readGroup"].contains(action), let identifier = request["app"] as? String, !identifier.isEmpty {
            targetPane = controller.websitePane(matching: identifier)
            if targetPane == nil { return ["ok": false, "error": "No open app matches \u{201C}\(identifier)\u{201D}. Call list_open_pages to see what's open."] }
        } else {
            targetPane = controller.currentWebsitePane
        }
        guard let pane = targetPane, pane.didCreateView, pane.webView.url != nil else {
            return ["ok": false, "error": "There is no page open in Satellite to \(kind.declinedVerb)."]
        }
        do {
            switch action {
            case "read":
                let text = try await PageSnapshot.capture(pane.webView, options: .init(forAssistant: true))
                return ["ok": true, "text": text]
            case "readGroup":
                guard let name = request["group"] as? String, !name.isEmpty else {
                    return ["ok": false, "error": "A group name is required."]
                }
                guard let tabGroup = pane.tabHost, let cluster = tabGroup.cluster(named: name) else {
                    return ["ok": false, "error": "No open tab group named \u{201C}\(name)\u{201D} in that app."]
                }
                let members = tabGroup.panes(in: cluster).filter { $0.didCreateView && $0.webView.url != nil }
                guard !members.isEmpty else { return ["ok": false, "error": "That group has no loaded pages in it."] }
                var sections: [String] = []
                for member in members {
                    sections.append(try await PageSnapshot.capture(member.webView, options: .init(forAssistant: true)))
                }
                return ["ok": true, "text": sections.joined(separator: "\n---\n\n")]
            case "click":
                guard let selector = request["selector"] as? String, !selector.isEmpty else {
                    return ["ok": false, "error": "A selector is required."]
                }
                let found = try await PageInteraction.click(pane.webView, selector: selector)
                return found ? ["ok": true, "text": "Clicked \(selector)."] : ["ok": false, "error": "No element matched \(selector)."]
            case "type":
                guard let selector = request["selector"] as? String, !selector.isEmpty, let text = request["text"] as? String else {
                    return ["ok": false, "error": "A selector and text are required."]
                }
                let pressEnter = request["pressEnter"] as? Bool ?? false
                let found = try await PageInteraction.type(pane.webView, selector: selector, text: text, pressEnter: pressEnter)
                return found ? ["ok": true, "text": "Typed into \(selector)\(pressEnter ? " and pressed Enter" : "")."] : ["ok": false, "error": "No element matched \(selector)."]
            default:
                return ["ok": false, "error": "Unknown action \u{201C}\(action)\u{201D}."]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private enum Kind {
        case read, write
        var trustPrefix: String { switch self { case .read: return "mcp-read"; case .write: return "mcp-write" } }
        var declinedVerb: String { switch self { case .read: return "read"; case .write: return "act on" } }
    }

    private static func confirm(_ kind: Kind, label: String, window: NSWindow?) async -> AssistantSender.Answer {
        let alert = NSAlert()
        switch kind {
        case .read:
            alert.messageText = "Let \(label) read this page?"
            alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to read the page open in the apps panel \u{2014} its URL, title and visible content. Pages can hold customer data, so only allow agents approved for it.\n\nPage text: \(SnapshotTextMode.current.summary) (change this in Settings > General)."
        case .write:
            alert.messageText = "Let \(label) click and type on this page?"
            alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to click and type on the page open in the apps panel \u{2014} which can submit forms and change data, including in Salesforce. This isn\u{2019}t limited to one field or action: once allowed, it can act anywhere on the page without asking again. Only allow agents you trust with that."
        }
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
