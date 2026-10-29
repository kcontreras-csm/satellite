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
    /// Asks the user whether an agent may read or write; an alert in the app, replaceable for checks.
    var confirm: (_ kind: Kind, _ agent: String, _ window: NSWindow?) async -> AssistantSender.Answer = MCPBridge.askWithAlert

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
            MCPSocket.ignoreBrokenPipe(client)
            guard let request = MCPSocket.receiveLine(from: client, limit: MCPSocket.requestLimit) else { close(client); continue }
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
            let answer = await confirm(kind, label, controller.window)
            guard answer.send else { return ["ok": false, "error": "The user didn\u{2019}t allow \(label) to \(kind.declinedVerb)."] }
            if answer.remember { trust.set(trustID, trusted: true) }
        }
        do {
            switch action {
            case "list":
                return ["ok": true, "text": Self.listing(controller.openPages(), groups: controller.satelliteGroups, front: controller.currentWebsitePane)]
            case "read":
                let page: OpenPage?
                if let tab = request["tab"] as? String, !tab.isEmpty {
                    page = controller.page(withID: tab)
                    if page == nil { return ["ok": false, "error": "No open page has the id \u{201C}\(tab)\u{201D}. Call list_open_pages for the current ids."] }
                } else if let app = request["app"] as? String, !app.isEmpty {
                    page = controller.currentPage(ofApp: app)
                    if page == nil { return ["ok": false, "error": "No app, loaded tab group or assistant matches \u{201C}\(app)\u{201D}. Call list_open_pages to see what\u{2019}s open."] }
                } else {
                    page = controller.openPages().first { $0.pane === controller.currentWebsitePane }
                    if page == nil { return ["ok": false, "error": "No page is shown now (Satellite is showing its list of tab groups). Use read_page with an id from list_open_pages."] }
                }
                guard let page, page.isLoaded else {
                    return ["ok": false, "error": "That page hasn\u{2019}t loaded yet, so there\u{2019}s nothing to read. Open it in Satellite, or wait for it to load."]
                }
                let text = try await Self.snapshot(page.pane)
                return ["ok": true, "text": Self.fitted(text, note: "The rest of this page didn\u{2019}t fit.")]
            case "readGroup":
                guard let name = request["group"] as? String, !name.isEmpty else {
                    return ["ok": false, "error": "A group name is required."]
                }
                let groups = controller.satelliteGroups
                guard let saved = groups.group(named: name) else {
                    return ["ok": false, "error": "No tab group is named \u{201C}\(name)\u{201D}. Call list_open_pages to see the groups."]
                }
                guard let tabs = groups.loaded[saved.id] else {
                    return ["ok": false, "error": "\u{201C}\(saved.name)\u{201D} isn\u{2019}t loaded, so its pages aren\u{2019}t open to read. Ask the user to press Load next to it in Satellite\u{2019}s Groups view (Groups in the rail)."]
                }
                let members = tabs.tabs.filter { $0.didCreateView && $0.webView.url != nil }
                guard !members.isEmpty else { return ["ok": false, "error": "\u{201C}\(saved.name)\u{201D} has no loaded pages yet. Try again once they\u{2019}ve loaded."] }
                // The pages share one answer's room, so a large first page can't push the others out of sight.
                var sections: [String] = []
                for member in members {
                    sections.append(try await Self.snapshot(member, sharedBy: members.count))
                }
                let joined = sections.joined(separator: "\n---\n\n")
                return ["ok": true, "text": Self.fitted(joined, note: "Read the group\u{2019}s pages one at a time with read_page (ids in list_open_pages) to see each in full.")]
            default:
                break
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        // Clicking and typing only ever act on the page in front: reading a tab you aren't looking at is one
        // thing, changing one is another.
        guard let pane = controller.currentWebsitePane, pane.didCreateView, pane.webView.url != nil else {
            return ["ok": false, "error": "No page is shown in Satellite now (it may be showing its list of tab groups), so there\u{2019}s nothing to click or type on."]
        }
        do {
            switch action {
            case "click":
                guard let selector = request["selector"] as? String, !selector.isEmpty else {
                    return ["ok": false, "error": "A selector is required."]
                }
                let before = (url: pane.webView.url, title: pane.webView.title)
                guard let clicked = try await PageInteraction.click(pane.webView, selector: selector) else {
                    return ["ok": false, "error": "No element matched \(selector). Read the page again for current selectors."]
                }
                var text = "Clicked " + (clicked.inside ?? selector) + "."
                // Whether it led somewhere (a single-page app like Lightning changes its address without loading).
                let end = Date().addingTimeInterval(2)
                while Date() < end, pane.webView.url == before.url, pane.webView.title == before.title {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if pane.webView.url != before.url || pane.webView.title != before.title {
                    // The address changes first; let the new page load (and name itself) before saying what it is.
                    let settle = Date().addingTimeInterval(3)
                    while Date() < settle, pane.webView.isLoading { try await Task.sleep(nanoseconds: 100_000_000) }
                    text += " The page is now \u{201C}\(pane.webView.title ?? "")\u{201D} \(pane.webView.url?.absoluteString ?? "")."
                } else {
                    text += " The page\u{2019}s address and title didn\u{2019}t change (fine for a button that acts in place; if it should have opened something, it may not have)."
                }
                return ["ok": true, "text": text]
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

    /// Claude Code keeps at most 25,000 tokens of a tool's answer by default (about 100,000 characters) and cuts the
    /// rest unseen. Answers stay under that, so what an agent gets is all there is, or says where it was cut.
    static let outputLimit = 90_000

    /// A page as `read_page` gives it, sized so `sharedBy` of them fit in one answer: big pages come in less
    /// detail rather than being cut off partway.
    private static func snapshot(_ pane: WebPane, sharedBy count: Int = 1) async throws -> String {
        var options = PageSnapshot.Options(forAssistant: true)
        options.text = SnapshotTextMode.forAgents
        options.textSetting = "Page text for agents"
        // The answer's room, about 90,000 characters, goes to what an agent uses most: the controls it can act on,
        // and the page's text; the HTML gets what's left.
        options.forAgent = true
        options.interactiveLimit = max(25, 300 / count)
        options.interactiveChars = max(4_000, 25_000 / count)
        options.visibleText = max(5_000, 30_000 / count)
        options.mainBudget = max(5_000, 25_000 / count)
        options.frameBudget = max(2_000, 6_000 / count)
        return try await PageSnapshot.capture(pane.webView, options: options)
    }

    private static func fitted(_ text: String, note: String) -> String {
        guard text.count > outputLimit else { return text }
        return String(text.prefix(outputLimit)) + "\n\n[Cut here to fit an agent\u{2019}s tool output limit. \(note)]"
    }

    /// What `list_open_pages` returns: every page with its id — by app, then by tab group (unloaded groups too, so
    /// an agent knows they exist), then the web assistants.
    private static func listing(_ pages: [OpenPage], groups: SatelliteGroups, front: WebPane?) -> String {
        var lines = ["Pages open in Satellite. Pass a page\u{2019}s id as `tab` to read_page to read it, wherever it is and whether or not it\u{2019}s shown. Apps not opened yet, and tab groups not loaded, have no pages to read."]

        func describe(_ page: OpenPage) -> String {
            guard page.isLoaded else { return "- [\(page.pane.pageID)] still loading" }
            var line = "- [\(page.pane.pageID)] "
            if page.kind == .assistant { line += "\(page.owner) (assistant \u{201C}\(page.ownerID)\u{201D}): " }
            line += "\u{201C}\(page.pane.tabTitle)\u{201D} \(page.pane.webView.url?.absoluteString ?? "")"
            var notes: [String] = []
            if page.pane === front {
                notes.append("shown now")
            } else if page.isCurrentTab, page.kind != .assistant {
                notes.append(page.kind == .group ? "its group\u{2019}s current tab" : "its app\u{2019}s current tab")
            }
            if page.kind == .group, page.pane.groupMemberID == nil { notes.append("opened from the group, not saved in it") }
            if !notes.isEmpty { line += " (\(notes.joined(separator: ", ")))" }
            return line
        }

        var lastOwner: String?
        for page in pages where page.kind == .app {
            if page.ownerID != lastOwner {
                lines.append("\n\(page.owner) (app \u{201C}\(page.ownerID)\u{201D})")
                lastOwner = page.ownerID
            }
            lines.append(page.pane.didCreateView ? describe(page) : "- not opened yet")
        }

        if !groups.saved.isEmpty {
            lines.append("\nTab groups (read a whole one with read_tab_group)")
            for saved in groups.saved {
                let count = saved.members.count == 1 ? "1 page" : "\(saved.members.count) pages"
                lines.append("\(saved.name) (\(count), \(groups.isLoaded(saved.id) ? "loaded" : "not loaded"))")
                let tabs = pages.filter { $0.kind == .group && $0.ownerID == saved.id }
                if !tabs.isEmpty {
                    tabs.forEach { lines.append(describe($0)) }
                } else if saved.members.isEmpty {
                    lines.append("- no pages yet")
                } else {
                    lines.append("- not loaded: the user can press Load next to it in Satellite\u{2019}s Groups view")
                }
            }
        }

        let assistants = pages.filter { $0.kind == .assistant }
        if !assistants.isEmpty {
            lines.append("\nAssistants")
            assistants.forEach { lines.append(describe($0)) }
        }
        return lines.joined(separator: "\n")
    }

    enum Kind {
        case read, write
        // The read key changes whenever what reading shares grows (from the page in front to every open page, then
        // from interface labels to all page text by default), so an approval given for less isn't silently
        // stretched to cover more: the agent is asked once again, under the new wording.
        var trustPrefix: String { switch self { case .read: return "mcp-read-text"; case .write: return "mcp-write" } }
        var declinedVerb: String { switch self { case .read: return "read pages open in Satellite"; case .write: return "click and type on the page in front" } }
    }

    static func askWithAlert(_ kind: Kind, label: String, window: NSWindow?) async -> AssistantSender.Answer {
        let alert = NSAlert()
        switch kind {
        case .read:
            alert.messageText = "Let \(label) read the pages open in Satellite?"
            alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to read pages open in Satellite \u{2014} any tab of any app, of any loaded tab group, and the web assistants, not only the one in front: their URLs, titles and visible content. Pages can hold customer data, so only allow agents approved for it.\n\nPage text: \(SnapshotTextMode.forAgents.summary) (change this in Settings > General > Page text for agents)."
        case .write:
            alert.messageText = "Let \(label) click and type on the page in front?"
            alert.informativeText = "\(label) is a command-line agent asking, through Satellite\u{2019}s local MCP server, to click and type on whichever page is in front in Satellite \u{2014} which can submit forms and change data, including in Salesforce. Allowed, it can act anywhere on that page; with \u{201C}Don\u{2019}t ask again\u{201D}, on whatever page is in front from now on, in any app, without asking. Only allow agents you trust with that."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t ask again for \(label)"
        // An agent can ask while the window is closed (Satellite keeps running) or another app is in front. A sheet
        // on a window no one can see would never be answered, and the agent would wait forever.
        if let window, !window.isVisible { window.makeKeyAndOrderFront(nil) }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
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
