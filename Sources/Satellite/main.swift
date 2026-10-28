import AppKit

// A tiny MCP server over stdio for an agent's config to spawn, relaying to the already-running app; see MCPBridge.
if CommandLine.arguments.dropFirst().contains("--mcp-stdio") {
    MCPStdioServer.run()
}

let app = SatelliteApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
