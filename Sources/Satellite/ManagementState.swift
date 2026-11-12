import Foundation

/// What a managed device remembers: its own keys, the admin it enrolled with, and the latest policy it has
/// applied. One file, `management.json`, readable only by this user (it holds the device's private keys).
///
/// Absent file ⇒ the device isn't enrolled, and Satellite behaves exactly as an unmanaged install.
struct ManagementState: Codable {
    var keys: Management.Keys.Stored
    var admin: Admin
    var policy: ManagementPolicy
    /// Shown to the admin in its device list; the Mac's host name by default.
    var deviceName: String
    /// The enrollment secret this device proves itself with (from a one-time token or the baked-in profile).
    /// Kept so the device can keep re-announcing itself until the admin acknowledges it.
    var enrollSecret: String
    /// Whether the admin has acknowledged this device (a welcome/policy came back). Until then it keeps sending
    /// enrollment announcements rather than plain check-ins.
    var confirmed: Bool = false

    struct Admin: Codable {
        var sign: String      // admin signing key, hex
        var kx: String        // admin agreement key, base64
        var name: String
        var host: String?     // relay host, when the token set one
        var enrolledAt: Date
    }

    static var fileURL: URL { AppPaths.support.appendingPathComponent("management.json") }

    static func load() -> ManagementState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.management.decode(ManagementState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder.management.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    static func remove() { try? FileManager.default.removeItem(at: fileURL) }
}

/// The rules an admin sets, carried in `policy` and `welcome` messages. Its `version` only rises; a device
/// ignores anything not newer than what it has applied, so a replayed older policy can't weaken it.
struct ManagementPolicy: Codable, Equatable {
    var version: Int
    var issuedAt: Double
    /// Extension ids that must be removed and may not be installed.
    var blockedIds: [String]
    /// Extension id → version the device must install and hold.
    var pinned: [String: String]
    /// Setting key → value the device must apply and lock. Keys: agent-text, snapshot-text, auto-update, mcp.
    var lockedSettings: [String: String]

    static let none = ManagementPolicy(version: 0, issuedAt: 0, blockedIds: [], pinned: [:], lockedSettings: [:])
}

extension JSONEncoder {
    static var management: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var management: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
