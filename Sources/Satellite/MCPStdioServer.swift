import Darwin
import Foundation

/// A tiny MCP (Model Context Protocol) server over stdio. An agent's MCP config spawns one of these per session
/// (`satellite --mcp-stdio`); it has no AppKit or WebKit of its own and offers exactly one tool, `read_active_page`,
/// which it relays over `MCPSocket` to the Satellite app already running. That app captures the page the same way
/// "Send to Assistant" does, and asks the user once per agent before sharing anything — see `MCPBridge`.
enum MCPStdioServer {
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
                respond(id, ["tools": [[
                    "name": "read_active_page",
                    "description": "Reads the page open in Satellite\u{2019}s apps panel (not this terminal): its URL, title and visible content as Markdown. Satellite asks the user once per agent before sharing it, the same as \u{201C}Send to Assistant\u{201D}.",
                    "inputSchema": ["type": "object", "properties": [String: Any]()],
                ] as [String: Any]]])
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                guard params["name"] as? String == "read_active_page" else {
                    respond(id, ["content": [["type": "text", "text": "Unknown tool."]], "isError": true]); break
                }
                switch readActivePage() {
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

    private struct ReadFailure: Error { let message: String }

    private static func readActivePage() -> Result<String, ReadFailure> {
        guard var addr = MCPSocket.address(for: MCPSocket.path) else {
            return .failure(ReadFailure(message: "Satellite\u{2019}s data path is too long for a socket."))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(ReadFailure(message: "Could not open a local socket.")) }
        defer { close(fd) }
        let size = MemoryLayout<sockaddr_un>.size
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(size)) }
        }
        guard connected == 0 else { return .failure(ReadFailure(message: "Satellite isn\u{2019}t running. Open it, then try again.")) }

        let paneID = ProcessInfo.processInfo.environment["SATELLITE_MCP_PANE_ID"] ?? ""
        MCPSocket.sendLine(["paneId": paneID], to: fd)
        guard let response = MCPSocket.receiveLine(from: fd) else {
            return .failure(ReadFailure(message: "Satellite closed the connection without answering."))
        }
        if response["ok"] as? Bool == true, let text = response["text"] as? String { return .success(text) }
        return .failure(ReadFailure(message: response["error"] as? String ?? "Satellite declined the request."))
    }
}
