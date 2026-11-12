import CryptoKit
import Foundation

/// A native client for Satella, the relay the `satellite-admin` tool and the Astroverse extension also use
/// (github.com/KiritoDv/Bellwood). It proves an Ed25519 player key, then sends and receives on relay channels.
/// The JavaScript client (tools/satellite-admin/satella.js) speaks the same wire protocol; keep them in step.
///
/// Used by `ManagementClient` so a managed Satellite can reach its admin without any web page being open.
actor SatellaConnection {
    static let defaultHost = "wss://sa-695a7ab59cca49a99418ac589afaded0.ecs.us-east-1.on.aws"
    private static let version = "1.0.0"
    private static let authTag = "satella-player-auth-v1:"
    private static let magic: [UInt8] = [0x48, 0x4d, 0x36, 0x34]   // "HM64"
    private enum FrameType: UInt8 { case json = 0x02, raw = 0x03, push = 0x04 }
    private static let pushRelay: UInt8 = 1
    private static let replyTimeout: TimeInterval = 10

    struct Relay { let channel: String; let sender: String; let text: String }

    private let host: String
    private let identity: Management.Keys
    private var channels: [String]
    private let onRelay: (Relay) -> Void
    /// Called when a live connection drops (not when `stop()` is used). Lets an owner reconnect and re-subscribe.
    private let onClose: () -> Void

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending: CheckedContinuation<Reply?, Never>?
    private var requestChain: Task<Void, Never> = Task {}
    private var running = false

    var isRunning: Bool { running }

    private struct Reply { let type: UInt8; let status: Int16; let body: String }

    init(host: String, identity: Management.Keys, channels: [String],
         onRelay: @escaping (Relay) -> Void, onClose: @escaping () -> Void = {}) {
        self.host = host
        self.identity = identity
        self.channels = channels
        self.onRelay = onRelay
        self.onClose = onClose
    }

    /// Listens on one more channel now (and again after any reconnect). No-op if already subscribed.
    func subscribe(_ channel: String) async throws {
        if !channels.contains(channel) { channels.append(channel) }
        guard running, task != nil else { return }   // the next handshake will subscribe it
        let reply = try await request(.json, "/v1/relay/\(wireID(channel))/subscribe")
        guard reply?.status == 200 else { throw Management.ProtocolError("Couldn\u{2019}t subscribe to \(channel).") }
    }

    private func wireID(_ channel: String) -> String { "\(channel)@\(Self.version)" }

    // MARK: Connecting

    /// Connects and completes the handshake (register, prove the key, subscribe). Throws if any step fails.
    func start() async throws {
        stop()
        running = true
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        guard let url = URL(string: "\(host)/ws?v=\(Self.version)") else { throw Management.ProtocolError("Bad relay host.") }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)

        let key = identity.signHex
        _ = try await request(.json, "/v1/player/\(key)/register")
        let challenge = try await request(.json, "/v1/player/challenge")
        if let body = challenge?.body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let nonce = json["nonce"] as? String, nonce.count == 64, let nonceBytes = Data(hex: nonce) {
            var message = Data(Self.authTag.utf8)
            message.append(nonceBytes)
            let signature = try identity.sign(message)
            let reply = try await request(.raw, "/v1/player/\(key)/verify", body: signature)
            guard reply?.status == 200 else { throw Management.ProtocolError("The relay didn\u{2019}t accept the key.") }
        } else {
            throw Management.ProtocolError("The relay didn\u{2019}t send a challenge.")
        }
        for channel in channels {
            let reply = try await request(.json, "/v1/relay/\(wireID(channel))/subscribe")
            guard reply?.status == 200 else { throw Management.ProtocolError("Couldn\u{2019}t subscribe to \(channel).") }
        }
    }

    func stop() {
        running = false
        pending?.resume(returning: nil)
        pending = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Sends text on a channel; nothing comes back.
    func send(_ text: String, on channel: String) async {
        guard let task else { return }
        let frame = Self.frame(.raw, route: "/v1/relay/\(wireID(channel))/send", body: Data(text.utf8))
        try? await task.send(.data(frame))
    }

    // MARK: Frames

    private static func frame(_ type: FrameType, route: String, body: Data = Data()) -> Data {
        let routeBytes = Data(route.utf8)
        var out = Data(magic)
        out.append(type.rawValue)
        var length = UInt32(routeBytes.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(routeBytes)
        out.append(body)
        return out
    }

    private static func parse(_ bytes: Data) -> (reply: Reply?, relay: (name: String, sender: String, payload: String)?)? {
        let b = [UInt8](bytes)
        guard b.count >= 5, b[0] == 0x48, b[1] == 0x4d else { return nil }
        let type = b[2]
        let status = Int16(bitPattern: UInt16(b[3]) | (UInt16(b[4]) << 8))
        let rest = Array(b[5...])
        if type != FrameType.push.rawValue {
            return (Reply(type: type, status: status, body: type == 0x01 ? "" : String(decoding: rest, as: UTF8.self)), nil)
        }
        guard rest.count >= 3 else { return nil }
        let nameLength = Int(rest[1]) | (Int(rest[2]) << 8)
        guard rest.count >= 3 + nameLength + 32 else { return nil }
        let name = String(decoding: rest[3..<(3 + nameLength)], as: UTF8.self)
        let senderBytes = Array(rest[(3 + nameLength)..<(3 + nameLength + 32)])
        let sender = senderBytes.allSatisfy { $0 == 0 } ? "" : Data(senderBytes).hexString
        let payload = String(decoding: rest[(3 + nameLength + 32)...], as: UTF8.self)
        return (nil, (name, sender, payload))
    }

    // MARK: Requests (answered in order)

    private func request(_ type: FrameType, _ route: String, body: Data = Data()) async throws -> Reply? {
        // Chain requests so a late reply is never taken for the next request's.
        let previous = requestChain
        let task = Task { await previous.value }
        requestChain = task
        await task.value
        guard let socket = self.task, running else { throw Management.ProtocolError("Not connected.") }
        // Register `pending` BEFORE sending: the relay can reply faster than the send call returns, and a reply
        // that arrives with no pending continuation would be dropped and the request would hang until timeout.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Reply?, Never>) in
            self.pending = continuation
            let frame = Self.frame(type, route: route, body: body)
            Task { try? await socket.send(.data(frame)) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.replyTimeout * 1_000_000_000))
                await self?.timeout(route)
            }
        }
    }

    private func timeout(_ route: String) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: nil)
        // A late reply would land on the next request, so drop the socket.
        task?.cancel(with: .protocolError, reason: Data("no reply to \(route)".utf8))
    }

    private func deliver(_ reply: Reply) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: reply)
    }

    private nonisolated func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { await self.deliverNil() }
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                Task { await self.received(data) }
                self.receiveLoop(task)
            }
        }
    }

    private func deliverNil() {
        pending?.resume(returning: nil)
        pending = nil
        if running {   // the socket dropped on its own (not stop()); let the owner reconnect
            running = false
            onClose()
        }
    }

    private func received(_ data: Data) {
        guard let parsed = Self.parse(data) else { return }
        if let relay = parsed.relay {
            if let channel = channels.first(where: { wireID($0) == relay.name }) {
                onRelay(Relay(channel: channel, sender: relay.sender, text: relay.payload))
            }
        } else if let reply = parsed.reply {
            deliver(reply)
        }
    }
}
