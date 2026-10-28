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
    /// Set for an assistant that is a terminal rather than a web page. Only config.json makes one: extensions can't.
    var terminal: TerminalConfig?
    /// When true, the toolbar's address bar can be typed into while this app is in front, to go to another
    /// address. Off (nil) by default: apps are configured destinations, so the bar is read-only and copyable.
    var editableAddress: Bool?

    var isTerminal: Bool { terminal != nil }

    /// The placeholder address a terminal entry carries (it has no page); never loaded.
    static func terminalURL(id: String) -> URL { URL(string: "satellite://terminal/\(id)")! }

    static func makeTerminal(id: String, name: String, symbol: String = "terminal", config: TerminalConfig = TerminalConfig()) -> WebApp {
        WebApp(id: id, name: name, url: terminalURL(id: id), symbol: symbol, terminal: config)
    }
}

/// What a terminal entry runs. Both parts are optional: with neither, it is your login shell in your home folder.
///
///     { "id": "terminal", "name": "Terminal", "symbol": "terminal", "terminal": {} }
///     { "id": "claude-code", "name": "Claude Code", "symbol": "sparkle", "terminal": { "command": "claude", "directory": "~/dot", "padding": 1 } }
struct TerminalConfig: Codable, Hashable {
    /// Run through your login shell (so your PATH applies); when it exits, an interactive shell takes over.
    var command: String?
    /// The folder to start in, "~" for home. Defaults to the home folder.
    var directory: String?
    /// A Gogh theme by name, e.g. "Dracula"; nil (or a name Satellite doesn't know) follows the system's light or
    /// dark text colors.
    var theme: String?
    /// Room around the text on every side, in characters (the width of one); nil is none. 0...10.
    var padding: Double?

    static let paddingRange: ClosedRange<Double> = 0...10
    /// `padding` as it applies: in range, 0 when unset.
    var effectivePadding: Double { min(max(padding ?? 0, Self.paddingRange.lowerBound), Self.paddingRange.upperBound) }
}

// A terminal entry needs no "url" in config.json; written back, it has none either.
extension WebApp {
    private enum CodingKeys: String, CodingKey { case id, name, url, symbol, tabs, terminal, editableAddress }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        tabs = try container.decodeIfPresent(Bool.self, forKey: .tabs)
        terminal = try container.decodeIfPresent(TerminalConfig.self, forKey: .terminal)
        editableAddress = try container.decodeIfPresent(Bool.self, forKey: .editableAddress)
        url = terminal == nil ? try container.decode(URL.self, forKey: .url) : Self.terminalURL(id: id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if terminal == nil { try container.encode(url, forKey: .url) }
        try container.encode(symbol, forKey: .symbol)
        try container.encodeIfPresent(tabs, forKey: .tabs)
        try container.encodeIfPresent(terminal, forKey: .terminal)
        try container.encodeIfPresent(editableAddress, forKey: .editableAddress)
    }
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

/// A tab group's color, from a fixed palette (so it's easy to pick from a menu and survives in config.json).
enum GroupColor: String, Codable, CaseIterable {
    case gray, blue, red, orange, yellow, green, pink, purple

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A Satellite tab group: pages from any apps or addresses, kept together under a name. It is saved whether or
/// not its pages are loaded; see `SatelliteGroups` for loading.
///
///     { "id": "…", "name": "Case 476168508", "color": "blue",
///       "members": [{ "id": "…", "name": "OrgCS", "url": "https://orgcs.lightning.force.com/…", "appID": "orgcs" }] }
struct SavedGroup: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: GroupColor
    var members: [GroupMember]

    init(id: String = UUID().uuidString, name: String, color: GroupColor, members: [GroupMember]) {
        self.id = id
        self.name = name
        self.color = color
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case id, name, color, members }

    // A color this version doesn't know (edited by hand, or from a newer one) is gray, not an unreadable file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = (try? container.decode(GroupColor.self, forKey: .color)) ?? .gray
        members = try container.decodeIfPresent([GroupMember].self, forKey: .members) ?? []
    }
}

/// One page of a tab group: the address it opens at (not wherever it was navigated to later, which can be a
/// sign-in redirect carrying a token).
struct GroupMember: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var url: URL
    /// The app it was added from, for its icon; nil for an address typed in.
    var appID: String?
}

struct AppConfig: Codable {
    var apps: [WebApp]
    var assistants: [WebApp]
    var store: StoreConfig?
    /// Tab groups; nil (left out of config.json) when there are none.
    var groups: [SavedGroup]?

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
            WebApp.makeTerminal(id: "terminal", name: "Terminal"),
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
