import Foundation

// MARK: - Author

struct ExtensionAuthor: Codable, Hashable {
    var name: String
    var email: String?
    var url: String?

    init(name: String, email: String? = nil, url: String? = nil) {
        self.name = name
        self.email = email
        self.url = url
    }

    /// Accepts either "Jane Doe" or { "name": "Jane Doe", "email": "...", "url": "..." }.
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            self.init(name: text.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try keyed.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines),
            email: try keyed.decodeIfPresent(String.self, forKey: .email),
            url: try keyed.decodeIfPresent(String.self, forKey: .url))
    }

    private enum CodingKeys: String, CodingKey { case name, email, url }
}

// MARK: - Permissions

/// What an extension's `satellite` API calls are allowed to do. Shown to the user before install
/// and enforced by the native bridge.
enum ExtensionPermission: String, Codable, CaseIterable, Hashable {
    case storage
    case notifications
    case openExternal = "open-external"
    case ui
    case shortcuts

    var summary: String {
        switch self {
        case .storage: return "Save its own data on this Mac"
        case .notifications: return "Show macOS notifications"
        case .openExternal: return "Open links in your default browser"
        case .ui: return "Add or change items in the sidebar and the assistants panel"
        case .shortcuts: return "Add keyboard shortcuts and menu commands"
        }
    }
}

// MARK: - Icon

enum ExtensionIconSpec: Equatable {
    case symbol(String)
    case file(String)
    case none

    static let allowedFileExtensions: Set<String> = ["png", "jpg", "jpeg", "svg"]

    /// "symbol:bolt.fill" uses an SF Symbol, anything else is a file inside the extension folder.
    /// Absent, empty or unusable values mean `.none`, which the UI renders as a generated monogram.
    init(_ icon: String?) {
        guard let icon = icon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else {
            self = .none
            return
        }
        if icon.hasPrefix("symbol:") {
            let name = String(icon.dropFirst("symbol:".count))
            self = name.isEmpty ? .none : .symbol(name)
        } else if ExtensionManifest.isSafeRelativePath(icon),
                  Self.allowedFileExtensions.contains((icon as NSString).pathExtension.lowercased()) {
            self = .file(icon)
        } else {
            self = .none
        }
    }
}

// MARK: - Manifest

struct ManifestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A validated extension manifest. The on-disk format is documented in the README;
/// `parse` turns a manifest.json into this type or throws a human-readable `ManifestError`.
struct ExtensionManifest: Codable, Hashable {
    enum Kind: String, Codable {
        case contentScript = "content-script"
        case library
    }

    var id: String
    var name: String
    var version: String
    var author: ExtensionAuthor
    var description: String
    var icon: String?
    var homepage: String?
    var license: String?
    var category: String?
    var keywords: [String]
    var kind: Kind
    var dependencies: [String: String]
    var minAppVersion: String?
    var permissions: [ExtensionPermission]
    var matches: [String]
    var excludeMatches: [String]
    var js: [String]
    var css: [String]
    var runAt: String
    var allFrames: Bool
    var world: String
    var background: String?
    var settings: [SettingDefinition]

    var semver: SemVer { SemVer(version) ?? SemVer(0, 0, 0) }
    var iconSpec: ExtensionIconSpec { ExtensionIconSpec(icon) }
    var isLibrary: Bool { kind == .library }
    var runsOnPages: Bool { !matches.isEmpty }
    /// Every file in the folder the extension needs in order to run.
    var codeFiles: [String] { js + css + (background.map { [$0] } ?? []) }
    var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }

    var dependencyRanges: [(id: String, range: VersionRange)] {
        dependencies.keys.sorted().compactMap { key in
            VersionRange(dependencies[key] ?? "").map { (key, $0) }
        }
    }

    /// Set when the running Satellite is older than the extension needs.
    var compatibilityProblem: String? {
        guard let minimum = minAppVersion.flatMap(SemVer.init), AppInfo.version < minimum else { return nil }
        return "Requires Satellite \(minimum) or newer (this is \(AppInfo.version))"
    }

    // MARK: Parsing

    static let validRunAt: Set<String> = ["document_start", "document_end", "document_idle"]
    static let validWorlds: Set<String> = ["isolated", "main"]

    static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, (1...64).contains(id.count) else { return false }
        let alnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let rest = alnum.union(CharacterSet(charactersIn: "._-"))
        return alnum.contains(first) && id.unicodeScalars.allSatisfy(rest.contains)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    static func parse(_ data: Data, folderName: String) throws -> ExtensionManifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError("manifest.json: " + describe(error))
        } catch {
            throw ManifestError("manifest.json is not valid JSON")
        }

        guard isValidID(folderName) else {
            throw ManifestError("Folder name \u{201C}\(folderName)\u{201D} must be 1\u{2013}64 characters: lowercase letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} or \u{201C}_\u{201D}, starting with a letter or digit")
        }
        if let declared = raw.id, declared != folderName {
            throw ManifestError("\u{201C}id\u{201D} (\(declared)) must match the folder name (\(folderName))")
        }

        func required(_ value: String?, _ key: String) throws -> String {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw ManifestError("missing required field \u{201C}\(key)\u{201D}")
            }
            return text
        }
        let name = try required(raw.name, "name")
        let version = try required(raw.version, "version")
        guard SemVer(version) != nil else {
            throw ManifestError("\u{201C}version\u{201D} must look like 1.2.3 (got \u{201C}\(version)\u{201D})")
        }
        guard let author = raw.author, !author.name.isEmpty else {
            throw ManifestError("missing required field \u{201C}author\u{201D}")
        }
        let description = try required(raw.description, "description")

        let kind: Kind
        switch raw.type ?? "content-script" {
        case "content-script": kind = .contentScript
        case "library": kind = .library
        case let other: throw ManifestError("\u{201C}type\u{201D} must be \u{201C}content-script\u{201D} or \u{201C}library\u{201D} (got \u{201C}\(other)\u{201D})")
        }

        let runAt = raw.runAt ?? "document_end"
        guard validRunAt.contains(runAt) else {
            throw ManifestError("\u{201C}run_at\u{201D} must be document_start, document_end or document_idle")
        }
        let world = raw.world ?? "isolated"
        guard validWorlds.contains(world) else {
            throw ManifestError("\u{201C}world\u{201D} must be \u{201C}isolated\u{201D} or \u{201C}main\u{201D}")
        }

        var permissions: [ExtensionPermission] = []
        for text in raw.permissions ?? [] {
            guard let permission = ExtensionPermission(rawValue: text) else {
                let known = ExtensionPermission.allCases.map(\.rawValue).joined(separator: ", ")
                throw ManifestError("unknown permission \u{201C}\(text)\u{201D} (known: \(known))")
            }
            if !permissions.contains(permission) { permissions.append(permission) }
        }

        let dependencies = raw.dependencies ?? [:]
        for (key, range) in dependencies {
            guard isValidID(key) else { throw ManifestError("dependency \u{201C}\(key)\u{201D} is not a valid extension id") }
            guard key != folderName else { throw ManifestError("an extension cannot depend on itself") }
            guard VersionRange(range) != nil else {
                throw ManifestError("dependency \u{201C}\(key)\u{201D} has an invalid version range \u{201C}\(range)\u{201D}")
            }
        }

        if let minimum = raw.minAppVersion, SemVer(minimum) == nil {
            throw ManifestError("\u{201C}min_app_version\u{201D} must look like 1.2.3")
        }
        if let homepage = raw.homepage {
            guard let url = URL(string: homepage), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw ManifestError("\u{201C}homepage\u{201D} must be an http(s) URL")
            }
        }

        let matches = raw.matches ?? []
        let js = raw.js ?? []
        let css = raw.css ?? []
        for file in js + css where !isSafeRelativePath(file) {
            throw ManifestError("\u{201C}\(file)\u{201D} is not a valid relative file path")
        }
        switch kind {
        case .contentScript:
            if matches.isEmpty {
                guard js.isEmpty, css.isEmpty else {
                    throw ManifestError("\u{201C}js\u{201D} and \u{201C}css\u{201D} need \u{201C}matches\u{201D} to say which pages to run on")
                }
                guard raw.background != nil else {
                    throw ManifestError("needs \u{201C}matches\u{201D} with a \u{201C}js\u{201D} or \u{201C}css\u{201D} file, or a \u{201C}background\u{201D} script")
                }
            } else {
                guard !js.isEmpty || !css.isEmpty else { throw ManifestError("needs at least one \u{201C}js\u{201D} or \u{201C}css\u{201D} file") }
            }
            for pattern in matches + (raw.excludeMatches ?? []) { _ = try MatchPattern.regexSource(pattern) }
        case .library:
            guard !js.isEmpty else { throw ManifestError("a library needs at least one \u{201C}js\u{201D} file") }
            guard raw.background == nil else { throw ManifestError("a library cannot have a \u{201C}background\u{201D} script") }
        }
        if let background = raw.background {
            guard isSafeRelativePath(background) else { throw ManifestError("\u{201C}\(background)\u{201D} is not a valid relative file path") }
            guard world == "isolated" else {
                throw ManifestError("a \u{201C}background\u{201D} script needs \u{201C}world\u{201D} to be \u{201C}isolated\u{201D}")
            }
        }

        let settings = try (raw.settings ?? []).map { try $0.validated() }
        guard settings.count <= ExtensionSettings.maxSettings else {
            throw ManifestError("at most \(ExtensionSettings.maxSettings) settings are allowed")
        }
        var seenKeys = Set<String>()
        for setting in settings where !seenKeys.insert(setting.key).inserted {
            throw ManifestError("setting \u{201C}\(setting.key)\u{201D} is listed twice")
        }

        return ExtensionManifest(
            id: folderName, name: name, version: version, author: author, description: description,
            icon: raw.icon, homepage: raw.homepage, license: raw.license, category: raw.category,
            keywords: raw.keywords ?? [], kind: kind, dependencies: dependencies, minAppVersion: raw.minAppVersion,
            permissions: permissions, matches: matches, excludeMatches: raw.excludeMatches ?? [], js: js, css: css,
            runAt: runAt, allFrames: raw.allFrames ?? false, world: world, background: raw.background, settings: settings)
    }

    /// Every file the manifest refers to, relative to the extension folder.
    var referencedFiles: [String] {
        var files = codeFiles
        if case .file(let path) = iconSpec { files.append(path) }
        return files
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? "" : "\u{201C}\(keys)\u{201D} "
        }
        switch error {
        case .keyNotFound(let key, _): return "missing \u{201C}\(key.stringValue)\u{201D}"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return path(context) + "has the wrong type"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "unreadable"
        }
    }
}

/// The manifest.json file format: every field optional at decode time so `parse` can give precise messages.
private struct RawManifest: Decodable {
    var id: String?
    var name: String?
    var version: String?
    var author: ExtensionAuthor?
    var description: String?
    var icon: String?
    var homepage: String?
    var license: String?
    var category: String?
    var keywords: [String]?
    var type: String?
    var dependencies: [String: String]?
    var minAppVersion: String?
    var permissions: [String]?
    var matches: [String]?
    var excludeMatches: [String]?
    var js: [String]?
    var css: [String]?
    var runAt: String?
    var allFrames: Bool?
    var world: String?
    var background: String?
    var settings: [SettingDefinition]?

    enum CodingKeys: String, CodingKey {
        case id, name, version, author, description, icon, homepage, license, category, keywords, type
        case dependencies, permissions, matches, js, css, world, background, settings
        case minAppVersion = "min_app_version"
        case excludeMatches = "exclude_matches"
        case runAt = "run_at"
        case allFrames = "all_frames"
    }
}

// MARK: - Install metadata

/// Written next to an extension installed from a store so updates and provenance can be tracked.
struct ExtensionOrigin: Codable, Hashable {
    static let fileName = ".satellite.json"

    /// Repository (or local folder) the extension was installed from.
    var source: String
    /// Branch, tag or commit it was read at.
    var ref: String
    var installedVersion: String
    var installedAt: Date

    static func read(from directory: URL) -> ExtensionOrigin? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExtensionOrigin.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
