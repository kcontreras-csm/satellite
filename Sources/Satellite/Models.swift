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
}

struct AppConfig: Codable {
    var apps: [WebApp]
    var assistants: [WebApp]

    static let defaults = AppConfig(
        apps: [
            WebApp(id: "lightning", name: "Lightning", url: URL(string: "https://orgcs.lightning.force.com/one/one.app")!, symbol: "cloud.fill"),
            WebApp(id: "bt2", name: "BT2", url: URL(string: "https://bt2.my.salesforce.com/")!, symbol: "bolt.fill"),
            // TODO: point this at the real knowledge base once decided (edit config.json).
            WebApp(id: "knowledge", name: "Knowledge", url: URL(string: "https://help.salesforce.com/")!, symbol: "book.fill"),
        ],
        assistants: [
            WebApp(id: "claude", name: "Claude", url: URL(string: "https://claude.ai/")!, symbol: "sparkle"),
            WebApp(id: "gemini", name: "Gemini", url: URL(string: "https://gemini.google.com/")!, symbol: "sparkles"),
            WebApp(id: "slack", name: "Slackbot", url: URL(string: "https://app.slack.com/client")!, symbol: "number"),
        ]
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
