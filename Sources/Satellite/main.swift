import AppKit

// A tiny MCP server over stdio for an agent's config to spawn, relaying to the already-running app; see MCPBridge.
if CommandLine.arguments.dropFirst().contains("--mcp-stdio") {
    MCPStdioServer.run()
}

// Headless device enrollment: `Satellite --enroll <token>`. Enrolls with an admin and exits, so it can be scripted
// across a team's machines. Satellite > Settings > Management does the same from the UI.
if let index = CommandLine.arguments.firstIndex(of: "--enroll") {
    let token = CommandLine.arguments.dropFirst(index + 1).first ?? ""
    Task { @MainActor in
        do {
            try await ManagementClient.shared.enroll(token: token, start: false)
            print("Enrolled. This Satellite is now managed by its administrator.")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(("Enrollment failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = SatelliteApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
