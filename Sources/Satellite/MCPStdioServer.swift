import AppKit
import Darwin
import Foundation

/// What to give an MCP client so it can start `MCPStdioServer`: this very Satellite (wherever it's installed, or the
/// build being run) with `--mcp-stdio`. Satellite > Install MCP Server copies either form.
enum MCPInstall {
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// For Claude Code's CLI, at user scope: the default scope is the folder it's run in, and a Satellite terminal
    /// can start anywhere.
    static func claudeCommand(executable: String = executable) -> String {
        "claude mcp add --scope user satellite -- \(TerminalPane.quoted(executable)) --mcp-stdio"
    }

    /// For a `.mcp.json` file, or any client whose config takes the same shape.
    static func json(executable: String = executable) -> String {
        let config = ["mcpServers": ["satellite": ["type": "stdio", "command": executable, "args": ["--mcp-stdio"]] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A tiny MCP (Model Context Protocol) server over stdio. An agent's MCP config spawns one of these per session
/// (`satellite --mcp-stdio`); it has no AppKit or WebKit of its own and relays each tool call over `MCPSocket` to
/// the Satellite app already running, which carries it out on the page open in the apps panel and asks the user
/// once per agent before any of it happens — see `MCPBridge`.
enum MCPStdioServer {
    private static let tools: [[String: Any]] = [
        [
            "name": "list_open_pages",
            "description": "Lists every page open in Satellite (not this terminal): each tab of each app, then each tab group (with whether it\u{2019}s loaded, and its tabs if so), then the web assistants \u{2014} each page with an id, its title and address, and which one is shown now. Pass an id to read_page to read that page, whether or not it\u{2019}s shown.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "read_page",
            "description": "Reads any page open in Satellite by its id from list_open_pages \u{2014} a background tab, another app\u{2019}s tab, or a web assistant \u{2014} without switching to it: its URL, title and visible content as Markdown. Satellite asks the user once per agent before sharing pages, the same as \u{201C}Send to Assistant\u{201D}.",
            "inputSchema": ["type": "object", "required": ["tab"],
                             "properties": ["tab": ["type": "string", "description": "A page id from list_open_pages."]]],
        ],
        [
            "name": "read_active_page",
            "description": "Reads the page shown now in Satellite\u{2019}s apps panel (not this terminal): its URL, title and visible content as Markdown, including a list of clickable elements with selectors for click_element and type_text. Pass `app` for another app\u{2019}s current tab instead; read_page reads any tab. Satellite asks the user once per agent before sharing pages, the same as \u{201C}Send to Assistant\u{201D}.",
            "inputSchema": ["type": "object",
                             "properties": ["app": ["type": "string", "description": "An app\u{2019}s or assistant\u{2019}s name or id, from list_open_pages. Omit for the page shown now."]]],
        ],
        [
            "name": "click_element",
            "description": "Clicks an element on the page open in Satellite\u{2019}s apps panel. `selector` is one from read_active_page’s “Interactive elements” (plain CSS, with `>>` where it crosses into a shadow root; one starting `frame:` acts inside that iframe, including other sites’). Clicking something that isn’t a control, like a table cell, clicks the link or button inside it; the answer says whether the page (or frame) went somewhere. Satellite asks the user once per agent before any agent can click or type on the page — a separate, stronger confirmation than reading.",
            "inputSchema": ["type": "object", "required": ["selector"],
                             "properties": ["selector": ["type": "string", "description": "A selector from read_active_page’s Interactive elements."]]],
        ],
        [
            "name": "type_text",
            "description": "Replaces the content of a field (or contenteditable element) on the page open in Satellite’s apps panel with `text`, optionally pressing Enter afterward (which also submits its form, if it has one). `selector` is one from read_active_page’s “Interactive elements”, including a frame’s (starting `frame:`).",
            "inputSchema": ["type": "object", "required": ["selector", "text"],
                             "properties": ["selector": ["type": "string", "description": "A selector from read_active_page’s Interactive elements."],
                                            "text": ["type": "string", "description": "Replaces the field’s current content."],
                                            "pressEnter": ["type": "boolean", "description": "Press Enter after typing (default false)."]]],
        ],
        [
            "name": "read_tab_group",
            "description": "Reads every page of a Satellite tab group (pages from any apps or addresses, kept together under a name) \u{2014} each as the same Markdown read_page returns, concatenated, so an agent can search across several related pages at once. The group must be loaded; list_open_pages says which are. If it isn\u{2019}t, ask the user to press Load next to it in Satellite\u{2019}s Groups view, which opens its pages in the background without switching to them.",
            "inputSchema": ["type": "object", "required": ["group"],
                             "properties": ["group": ["type": "string", "description": "The group\u{2019}s name, as in list_open_pages and Satellite\u{2019}s Groups view."]]],
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
            case "ping":
                respond(id, [:])   // the spec: answer promptly, with an empty result
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
        case "read_page":
            guard let tab = arguments["tab"] as? String, !tab.isEmpty else {
                return .failure(BridgeFailure(message: "read_page needs a `tab` id from list_open_pages."))
            }
            request["action"] = "read"
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

        MCPSocket.ignoreBrokenPipe(fd)
        MCPSocket.sendLine(request, to: fd)
        guard let response = MCPSocket.receiveLine(from: fd, limit: MCPSocket.responseLimit) else {
            return .failure(BridgeFailure(message: "Satellite closed the connection without answering."))
        }
        if response["ok"] as? Bool == true, let text = response["text"] as? String { return .success(text) }
        return .failure(BridgeFailure(message: response["error"] as? String ?? "Satellite declined the request."))
    }
}
