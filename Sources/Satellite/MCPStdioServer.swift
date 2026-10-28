import Darwin
import Foundation

/// A tiny MCP (Model Context Protocol) server over stdio. An agent's MCP config spawns one of these per session
/// (`satellite --mcp-stdio`); it has no AppKit or WebKit of its own and relays each tool call over `MCPSocket` to
/// the Satellite app already running, which carries it out on the page open in the apps panel and asks the user
/// once per agent before any of it happens — see `MCPBridge`.
enum MCPStdioServer {
    private static let tools: [[String: Any]] = [
        [
            "name": "list_open_pages",
            "description": "Lists every app open in Satellite (not this terminal), each with its current tab\u{2019}s title and address if it\u{2019}s been opened at least once. Use an entry\u{2019}s name or id as `app` in read_active_page or read_tab_group to read it without switching to it first.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "read_active_page",
            "description": "Reads a page open in Satellite\u{2019}s apps panel (not this terminal): its URL, title and visible content as Markdown, including a list of clickable elements with selectors for click_element and type_text. Defaults to whichever app is shown now; pass `app` (from list_open_pages) to read a different one without switching to it — its page keeps running in the background regardless. Satellite asks the user once per agent before sharing it, the same as \u{201C}Send to Assistant\u{201D}.",
            "inputSchema": ["type": "object",
                             "properties": ["app": ["type": "string", "description": "An app’s name or id, from list_open_pages. Omit to read whichever app is shown now."]]],
        ],
        [
            "name": "click_element",
            "description": "Clicks an element on the page open in Satellite\u{2019}s apps panel. `selector` is one from read_active_page’s “Interactive elements” (plain CSS, with `>>` where it crosses into a shadow root). Main frame only. Satellite asks the user once per agent before any agent can click or type on the page — a separate, stronger confirmation than reading.",
            "inputSchema": ["type": "object", "required": ["selector"],
                             "properties": ["selector": ["type": "string", "description": "A selector from read_active_page’s Interactive elements."]]],
        ],
        [
            "name": "type_text",
            "description": "Replaces the content of a field (or contenteditable element) on the page open in Satellite’s apps panel with `text`, optionally pressing Enter afterward (which also submits its form, if it has one). `selector` is one from read_active_page’s “Interactive elements”. Main frame only.",
            "inputSchema": ["type": "object", "required": ["selector", "text"],
                             "properties": ["selector": ["type": "string", "description": "A selector from read_active_page’s Interactive elements."],
                                            "text": ["type": "string", "description": "Replaces the field’s current content."],
                                            "pressEnter": ["type": "boolean", "description": "Press Enter after typing (default false)."]]],
        ],
        [
            "name": "read_tab_group",
            "description": "Reads every open tab in a named tab group (Satellite\u{2019}s Chrome-style groups: a colored chip plus the tabs grouped under it) \u{2014} each as the same Markdown read_active_page returns, concatenated, so an agent can search across several related pages at once. `group` is the group\u{2019}s name as shown on its chip in the tab bar. Defaults to whichever app is shown now; pass `app` (from list_open_pages) for a group in a different one.",
            "inputSchema": ["type": "object", "required": ["group"],
                             "properties": ["group": ["type": "string", "description": "A tab group\u{2019}s name, as shown on its chip in Satellite\u{2019}s tab bar."],
                                            "app": ["type": "string", "description": "An app’s name or id, from list_open_pages. Omit for whichever app is shown now."]]],
        ],
    ]

    static func run() -> Never {
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            let id = message["id"]
            switch method {
            case "initialize":
                let params = message["params"] as? [String: Any] ?? [:]
                let version = params["protocolVersion"] as? String ?? "2024-11-05"
                respond(id, ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                             "serverInfo": ["name": "satellite", "version": AppInfo.version.description]])
            case "notifications/initialized":
                break   // a notification: no reply expected or sent
            case "tools/list":
                respond(id, ["tools": tools])
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                switch callBridge(tool: params["name"] as? String ?? "", arguments: arguments) {
                case .success(let text): respond(id, ["content": [["type": "text", "text": text]], "isError": false])
                case .failure(let failure): respond(id, ["content": [["type": "text", "text": failure.message]], "isError": true])
                }
            default:
                if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]) }
            }
        }
        exit(0)
    }

    private static func respond(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }   // a notification has no id and expects no reply
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    // MARK: - Talking to the running app

    private struct BridgeFailure: Error { let message: String }

    private static func callBridge(tool: String, arguments: [String: Any]) -> Result<String, BridgeFailure> {
        var request = arguments
        switch tool {
        case "list_open_pages": request["action"] = "list"
        case "read_active_page": request["action"] = "read"
        case "click_element": request["action"] = "click"
        case "type_text": request["action"] = "type"
        case "read_tab_group": request["action"] = "readGroup"
        default: return .failure(BridgeFailure(message: "Unknown tool \u{201C}\(tool)\u{201D}."))
        }
        request["paneId"] = ProcessInfo.processInfo.environment["SATELLITE_MCP_PANE_ID"] ?? ""

        guard var addr = MCPSocket.address(for: MCPSocket.path) else {
            return .failure(BridgeFailure(message: "Satellite\u{2019}s data path is too long for a socket."))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(BridgeFailure(message: "Could not open a local socket.")) }
        defer { close(fd) }
        let size = MemoryLayout<sockaddr_un>.size
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(size)) }
        }
        guard connected == 0 else { return .failure(BridgeFailure(message: "Satellite isn\u{2019}t running. Open it, then try again.")) }

        MCPSocket.sendLine(request, to: fd)
        guard let response = MCPSocket.receiveLine(from: fd) else {
            return .failure(BridgeFailure(message: "Satellite closed the connection without answering."))
        }
        if response["ok"] as? Bool == true, let text = response["text"] as? String { return .success(text) }
        return .failure(BridgeFailure(message: response["error"] as? String ?? "Satellite declined the request."))
    }
}
