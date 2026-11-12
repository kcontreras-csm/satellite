import Foundation

/// Carries out an admin's policy on this device, and reports back what is installed. Everything here is a no-op
/// unless the device is enrolled (`ManagementClient`). The blocklist is also consulted at install time, so a
/// blocked extension can't be added back; see `ManagementClient.isBlocked`.
@MainActor
enum PolicyEnforcer {
    struct ExtensionReport: Codable {
        var id: String
        var version: String?
        var source: String       // "store", "github", "local", or "development"
        var enabled: Bool
    }

    /// Keys in a policy's lockedSettings → the UserDefaults key they drive and the values they map to.
    static let settingKeys: [String: String] = [
        "agent-text": SnapshotDefaults.agentTextMode,
        "snapshot-text": SnapshotDefaults.textMode,
        "auto-update": UpdateDefaults.autoCheck,
        "mcp": MCPDefaults.mode,
    ]

    static func inventory() -> [ExtensionReport] {
        ExtensionManager.shared.extensions.map { info in
            let source: String
            switch info.origin?.channel {
            case .github: source = "github"
            case .store: source = "store"
            case .none: source = info.inDevelopmentFolder ? "development" : "local"
            }
            return ExtensionReport(id: info.id, version: info.version?.description, source: source, enabled: info.isEnabled)
        }
    }

    /// Applies a whole policy: removes blocked extensions, installs pinned ones, and locks settings.
    static func apply(_ policy: ManagementPolicy) {
        UserDefaults.standard.set(policy.blockedIds, forKey: MCPDefaults.blockedExtensions)

        let manager = ExtensionManager.shared
        for id in policy.blockedIds where manager.info(id) != nil {
            try? manager.uninstall(id)
        }

        for (key, value) in policy.lockedSettings {
            guard let defaultsKey = settingKeys[key] else { continue }
            UserDefaults.standard.set(mappedValue(key, value), forKey: defaultsKey)
        }
        UserDefaults.standard.set(Array(policy.lockedSettings.keys), forKey: MCPDefaults.lockedSettings)
        // The MCP mode may have changed; start or stop the server to match (off = blocked entirely).
        if !policy.lockedSettings.keys.contains("mcp") { UserDefaults.standard.removeObject(forKey: MCPDefaults.mode) }
        MCPBridge.shared.applyMode()

        installPinned(policy.pinned)
    }

    static func run(_ command: String, on id: String) {
        let manager = ExtensionManager.shared
        switch command {
        case "uninstall": try? manager.uninstall(id)
        case "disable": manager.setEnabled(id, false)
        case "enable": manager.setEnabled(id, true)
        default: break
        }
    }

    // MARK: Helpers

    /// A locked setting's stored value differs from the policy word for the boolean ones.
    private static func mappedValue(_ key: String, _ value: String) -> Any {
        switch key {
        case "auto-update": return value == "on"
        default: return value   // agent-text / snapshot-text use the SnapshotTextMode raw value; mcp uses MCPMode raw value
        }
    }

    private static func installPinned(_ pinned: [String: String]) {
        guard !pinned.isEmpty else { return }
        let store = StoreModel.shared
        Task {
            await store.refresh()
            for (id, version) in pinned {
                let installed = ExtensionManager.shared.info(id)?.version?.description
                guard installed != version, let entry = store.index?.entries.first(where: { $0.id == id && $0.manifest.version == version }) else { continue }
                await store.install(entry)
            }
        }
    }
}
