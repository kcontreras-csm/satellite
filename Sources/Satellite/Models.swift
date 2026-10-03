import Foundation

enum AppPaths {
    static let support: URL = {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["SATELLITE_HOME"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("Satellite", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var extensions: URL { subdirectory("Extensions") }
    static var extensionData: URL { subdirectory("ExtensionData") }
    static var storeCache: URL { subdirectory("StoreCache") }
    static var config: URL { support.appendingPathComponent("config.json") }

    private static func subdirectory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct WebApp: Codable, Hashable {
    var id: String
    var name: String
    var url: URL
    var symbol: String
    /// When true, every link that asks for a new window opens as a tab inside this app, even links to other
    /// sites. Meant for launchers such as Okta, where each tile opens a different application.
    var tabs: Bool?
}

/// Where the extension store reads from. Optional in config.json; defaults to the official repository.
struct StoreConfig: Codable, Hashable {
    var repository: String = "kcontreras-csm/satellite-extensions"
    /// Branch to read; nil means the repository's default branch.
    var branch: String?
    /// Sub-folder that holds the extension folders; nil means the repository root.
    var directory: String?

    static let `default` = StoreConfig()
}

struct AppConfig: Codable {
    var apps: [WebApp]
    var assistants: [WebApp]
    var store: StoreConfig?

    var effectiveStore: StoreConfig { store ?? .default }

    static let defaults = AppConfig(
        apps: [
            WebApp(id: "orgcs", name: "OrgCS", url: URL(string: "https://orgcs.lightning.force.com/one/one.app")!, symbol: "cloud.fill"),
            WebApp(id: "bt1", name: "BT1", url: URL(string: "https://bt1.my.salesforce.com/")!, symbol: "bolt.fill"),
            WebApp(id: "okta", name: "Okta", url: URL(string: "https://salesforce.okta.com/")!, symbol: "person.badge.key.fill", tabs: true),
            WebApp(id: "splunk", name: "Splunk", url: URL(string: "https://splunk-web.log-analytics.monitoring.aws-esvc1-useast2.aws.sfdc.cl/en-US/app/launcher/home")!, symbol: "text.magnifyingglass"),
        ],
        assistants: [
            WebApp(id: "claude", name: "Claude", url: URL(string: "https://claude.ai/")!, symbol: "sparkle"),
            WebApp(id: "gemini", name: "Gemini", url: URL(string: "https://gemini.google.com/")!, symbol: "sparkles"),
            WebApp(id: "slack", name: "Slackbot", url: URL(string: "https://app.slack.com/client")!, symbol: "number"),
        ],
        store: .default
    )

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: AppPaths.config) else {
            defaults.save()
            return defaults
        }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data), !config.apps.isEmpty {
            return config
        }
        NSLog("Satellite: config.json is invalid or has no apps; using defaults (file left untouched)")
        return defaults
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: AppPaths.config, options: .atomic)
    }
}
