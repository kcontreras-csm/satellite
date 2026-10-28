import AppKit
import Darwin

/// Listens on a local Unix socket so `MCPStdioServer` — a tiny process an agent's MCP config spawns, such as Claude
/// Code running in a Terminal assistant — can list and read any page open in Satellite (every app's tabs and the
/// web assistants, shown or not: a background page keeps running, so nothing needs switching to), read a tab
/// group's pages at once, and click and type on the page in front.
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
        do {
            switch action {
            case "list":
                return ["ok": true, "text": Self.listing(controller.openPages(), front: controller.currentWebsitePane)]
            case "read":
                let page: OpenPage?
                if let tab = request["tab"] as? String, !tab.isEmpty {
                    page = controller.page(withID: tab)
                    if page == nil { return ["ok": false, "error": "No open page has the id \u{201C}\(tab)\u{201D}. Call list_open_pages for the current ids."] }
                } else if let app = request["app"] as? String, !app.isEmpty {
                    page = controller.currentPage(ofApp: app)
                    if page == nil { return ["ok": false, "error": "No app or assistant matches \u{201C}\(app)\u{201D}. Call list_open_pages to see what\u{2019}s open."] }
                } else {
                    page = controller.openPages().first { $0.pane === controller.currentWebsitePane }
                }
                guard let page, page.isLoaded else {
                    return ["ok": false, "error": "That page hasn\u{2019}t been opened yet, so there\u{2019}s nothing to read. Open it in Satellite first."]
                }
                return ["ok": true, "text": try await PageSnapshot.capture(page.pane.webView, options: .init(forAssistant: true))]
            case "readGroup":
                guard let name = request["group"] as? String, !name.isEmpty else {
                    return ["ok": false, "error": "A group name is required."]
                }
                let found = Self.tabGroups(named: name, in: controller.openPages(), app: request["app"] as? String)
                guard found.count == 1, let (tabGroup, cluster) = found.first else {
                    if found.isEmpty { return ["ok": false, "error": "No open tab group is named \u{201C}\(name)\u{201D}. Call list_open_pages to see the groups."] }
                    let apps = found.map { $0.0.home.name }.joined(separator: ", ")
                    return ["ok": false, "error": "More than one app has a group named \u{201C}\(name)\u{201D} (\(apps)). Pass `app` to choose one."]
                }
                let members = tabGroup.panes(in: cluster).filter { $0.didCreateView && $0.webView.url != nil }
                guard !members.isEmpty else { return ["ok": false, "error": "That group has no loaded pages in it."] }
                var sections: [String] = []
                for member in members {
                    sections.append(try await PageSnapshot.capture(member.webView, options: .init(forAssistant: true)))
                }
                return ["ok": true, "text": sections.joined(separator: "\n---\n\n")]
            default:
                break
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        // Clicking and typing only ever act on the page in front: reading a tab you aren't looking at is one
        // thing, changing one is another.
        guard let pane = controller.currentWebsitePane, pane.didCreateView, pane.webView.url != nil else {
            return ["ok": false, "error": "There is no page open in Satellite to \(kind.declinedVerb)."]
        }
        do {
            switch action {
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

    /// What `list_open_pages` returns: every page with its id, grouped by app, then the web assistants.
    private static func listing(_ pages: [OpenPage], front: WebPane?) -> String {
        var lines = ["Pages open in Satellite. Pass a page\u{2019}s id as `tab` to read_page to read it, whichever app it\u{2019}s in and whether or not it\u{2019}s shown. Apps not opened yet have no page to read."]
        var lastOwner: String?
        var listedAssistantsHeading = false
        for page in pages {
            if page.isAssistant, !listedAssistantsHeading {
                lines.append("\nAssistants")
                listedAssistantsHeading = true
            }
            if !page.isAssistant, page.ownerID != lastOwner {
                lines.append("\n\(page.owner) (app \u{201C}\(page.ownerID)\u{201D})")
            }
            lastOwner = page.ownerID
            guard page.isLoaded else { lines.append("- not opened yet"); continue }
            var line = "- [\(page.pane.pageID)] "
            if page.isAssistant { line += "\(page.owner) (assistant \u{201C}\(page.ownerID)\u{201D}): " }
            line += "\u{201C}\(page.pane.tabTitle)\u{201D} \(page.pane.webView.url?.absoluteString ?? "")"
            var notes: [String] = []
            if page.pane === front { notes.append("shown now") } else if page.isCurrentTab && !page.isAssistant { notes.append("its app\u{2019}s current tab") }
            if let group = page.group { notes.append("group \u{201C}\(group)\u{201D}") }
            if !notes.isEmpty { line += " (\(notes.joined(separator: ", ")))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Tab groups with this name (case-insensitive): in `app` if given, else in every app.
    private static func tabGroups(named name: String, in pages: [OpenPage], app: String?) -> [(TabGroup, TabCluster)] {
        var seen = Set<ObjectIdentifier>()
        var found: [(TabGroup, TabCluster)] = []
        for page in pages where !page.isAssistant {
            if let app, !app.isEmpty, page.ownerID != app, page.owner.localizedCaseInsensitiveCompare(app) != .orderedSame { continue }
            guard let host = page.pane.tabHost, seen.insert(ObjectIdentifier(host)).inserted,
                  let cluster = host.cluster(named: name) else { continue }
            found.append((host, cluster))
        }
        return found
    }

    private enum Kind {
        case read, write
        // The read key changed when reading grew from the page in front to every open page, so an approval
        // given for the narrower wording isn't silently stretched to cover the wider one.
        var trustPrefix: String { switch self { case .read: return "mcp-read-all"; case .write: return "mcp-write" } }
        var declinedVerb: String { switch self { case .read: return "read"; case .write: return "act on" } }
    }

    private static func confirm(_ kind: Kind, label: String, window: NSWindow?) async -> AssistantSender.Answer {
        let alert = NSAlert()
        switch kind {
        case .read:
            alert.messageText = "Let \(label) read the pages open in Satellite?"
            alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to read pages open in Satellite \u{2014} any tab of any app and the web assistants, not only the one in front: their URLs, titles and visible content. Pages can hold customer data, so only allow agents approved for it.\n\nPage text: \(SnapshotTextMode.current.summary) (change this in Settings > General)."
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
