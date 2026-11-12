import Foundation

/// Satellite's own front to the Satella relay for extensions. Instead of each extension shipping a copy of
/// satella.js and opening its own WebSocket to the relay, it calls `satellite.relay` (gated by the `relay`
/// permission) and Satellite keeps one native connection per extension (via `SatellaConnection`), so the relay is
/// reached in one place that Satellite controls.
///
/// Each extension gets its own persistent player identity, so its messages are attributed to it (the `sender` on
/// inbound messages) and its channels are its own. Inbound messages are delivered to the extension's pages and
/// background with `satellite.relay.onMessage` via the existing emit path (type `relay`).
@MainActor
final class RelayManager {
    static let shared = RelayManager()

    /// Satella channel ids, matching satella.js: 1–128 of letters, digits, dot, underscore, hyphen.
    static let channelPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,128}$")
    static let maxMessageBytes = 100_000

    private struct Conn {
        let connection: SatellaConnection
        var retry = 2.0
        var reconnecting = false
    }
    private var conns: [String: Conn] = [:]
    private var identities: [String: Management.Keys] = [:]

    struct RelayError: LocalizedError { let errorDescription: String? ; init(_ m: String) { errorDescription = m } }

    /// The extension's own sender key (hex), so it can recognize its own messages among those it receives.
    func identityHex(for id: String) -> String { keys(for: id).signHex }

    func subscribe(_ id: String, channel: String) async throws {
        try Self.check(channel)
        let conn = try await connection(for: id)
        try await conn.subscribe(channel)
    }

    func send(_ id: String, channel: String, text: String) async throws {
        try Self.check(channel)
        guard text.utf8.count <= Self.maxMessageBytes else { throw RelayError("Relay messages are limited to 100 KB.") }
        let conn = try await connection(for: id)
        await conn.send(text, on: channel)
    }

    /// Drops an extension's relay connection (on uninstall/disable).
    func stop(_ id: String) {
        if let conn = conns[id]?.connection { Task { await conn.stop() } }
        conns[id] = nil
    }

    /// Closes relay connections for extensions that are no longer active.
    func prune(keeping active: Set<String>) {
        for id in conns.keys where !active.contains(id) { stop(id) }
    }

    // MARK: Connection per extension

    private func connection(for id: String) async throws -> SatellaConnection {
        if let existing = conns[id]?.connection { return existing }
        let connection = SatellaConnection(
            host: SatellaConnection.defaultHost, identity: keys(for: id), channels: [],
            onRelay: { [weak self] relay in
                Task { @MainActor in self?.deliver(id, relay) }
            },
            onClose: { [weak self] in
                Task { @MainActor in self?.reconnect(id) }
            })
        conns[id] = Conn(connection: connection)
        try await connection.start()
        conns[id]?.retry = 2.0
        return connection
    }

    private func deliver(_ id: String, _ relay: SatellaConnection.Relay) {
        ExtensionManager.shared.emit(id, type: "relay", arguments: [[
            "channel": relay.channel, "sender": relay.sender, "text": relay.text,
        ]])
    }

    /// Reconnects after a dropped socket, backing off, and re-subscribes (start() replays the channel list).
    private func reconnect(_ id: String) {
        guard var conn = conns[id], !conn.reconnecting else { return }
        conn.reconnecting = true
        conns[id] = conn
        let delay = conn.retry
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard conns[id] != nil else { return }   // stopped meanwhile
            do {
                try await conn.connection.start()
                conns[id]?.reconnecting = false
                conns[id]?.retry = 2.0
            } catch {
                conns[id]?.reconnecting = false
                conns[id]?.retry = min(delay * 2, 60)
                reconnect(id)
            }
        }
    }

    // MARK: Identity

    private func keys(for id: String) -> Management.Keys {
        if let keys = identities[id] { return keys }
        let defaultsKey = "relay.identity.\(id)"
        if let text = UserDefaults.standard.string(forKey: defaultsKey), let data = Data(base64Encoded: text),
           let stored = try? JSONDecoder().decode(Management.Keys.Stored.self, from: data), let keys = try? Management.Keys(stored) {
            identities[id] = keys
            return keys
        }
        let keys = Management.Keys.create()
        if let data = try? JSONEncoder().encode(keys.stored) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: defaultsKey)
        }
        identities[id] = keys
        return keys
    }

    private static func check(_ channel: String) throws {
        let range = NSRange(channel.startIndex..., in: channel)
        guard channelPattern.firstMatch(in: channel, range: range) != nil else {
            throw RelayError("A relay channel is 1\u{2013}128 characters of letters, digits, \u{201C}.\u{201D}, \u{201C}_\u{201D} or \u{201C}-\u{201D}.")
        }
    }
}
