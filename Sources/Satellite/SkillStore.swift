import AppKit
import Foundation

/// A store for Claude Code skills, built like the extension store but simpler: a GitHub repository publishes a
/// `skills.json` listing each skill (id, name, description, version and its files with git blob SHAs), and
/// Satellite installs them into the user's Claude Code skills folder (`~/.claude/skills/<id>`), where Claude Code
/// picks them up. Installs are verified against the published SHAs, swapped in atomically, and tracked so updates
/// and removal work. A skill is a folder with a `SKILL.md` (its name and description in frontmatter) plus any
/// files it needs.

// MARK: - Paths

extension AppPaths {
    /// The Claude Code personal skills folder, `~/.claude/skills`. Overridable with SATELLITE_SKILLS_DIR for tests.
    /// This is the user's real Claude directory, not under SATELLITE_HOME, so Claude Code reads what we install.
    static var skills: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["SATELLITE_SKILLS_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Index types

struct SkillEntry: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var version: String
    var files: [StoreFile]

    var totalSize: Int { files.reduce(0) { $0 + $1.size } }
}

struct SkillIndex: Codable {
    var source: String
    var revision: String
    var etag: String?
    var fetchedAt: Date
    var entries: [SkillEntry]
}

/// Written into an installed skill folder as `.satellite-skill.json`, so updates and the store know where it came
/// from and what version is on disk.
struct SkillOrigin: Codable {
    static let fileName = ".satellite-skill.json"
    var source: String
    var ref: String
    var version: String
    var installedAt: Date

    static func read(from folder: URL) -> SkillOrigin? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillOrigin.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

enum SkillLimits {
    static let maxFiles = 100
    static let maxFileSize = 2_000_000
    static let maxTotalSize = 20_000_000
    static let maxIndexSize = 262_144
    static let maxSkills = 300
}

/// Valid skill id: a folder name Claude Code accepts. Lowercase letters, digits and hyphens.
let skillIDPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,63}$")

func isValidSkillID(_ id: String) -> Bool {
    skillIDPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
}

// MARK: - Source

protocol SkillSource {
    var identifier: String { get }
    func fetchIndex(cached: SkillIndex?) async throws -> SkillIndex
    func download(_ file: StoreFile, of entry: SkillEntry) async throws -> Data
}

enum SkillSourceFactory {
    static func make(_ config: StoreConfig) -> SkillSource {
        if let path = ProcessInfo.processInfo.environment["SATELLITE_SKILLS_STORE_DIR"], !path.isEmpty {
            return SkillLocalSource(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return SkillGitHubSource(config: config)
    }
}

// MARK: - GitHub source

/// Reads `skills.json` and each skill's files as plain files from raw.githubusercontent.com (no GitHub API, so no
/// rate limit), the same way the extension store reads a repository.
struct SkillGitHubSource: SkillSource {
    let repository: String
    let ref: String
    let directory: String
    private let rawBase: URL

    var identifier: String { "skills:" + repository }
    var webURL: URL? { URL(string: "https://github.com/\(repository)") }

    init(config: StoreConfig) {
        repository = config.repository
        ref = config.branch ?? "HEAD"
        directory = (config.directory ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        rawBase = URL(string: ProcessInfo.processInfo.environment["SATELLITE_GITHUB_RAW"] ?? "https://raw.githubusercontent.com")!
    }

    private struct IndexFile: Decodable {
        var version: Int?
        var skills: [SkillEntry]
    }

    func fetchIndex(cached: SkillIndex?) async throws -> SkillIndex {
        guard repository.split(separator: "/").count == 2 else { throw StoreError.invalidConfig("the skills repository must be \u{201C}owner/name\u{201D}") }
        let indexPath = directory.isEmpty ? "skills.json" : directory + "/skills.json"
        let url = rawURL(path: indexPath)
        var headers: [String: String] = [:]
        if let etag = cached?.etag, cached?.source == identifier, !(cached?.entries.isEmpty ?? true) { headers["If-None-Match"] = etag }
        let (data, response) = try await fetch(url, maxBytes: SkillLimits.maxIndexSize, headers: headers)
        if response.statusCode == 304, let cached { return cached }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw StoreError.indexNotFound(url.absoluteString) }
            throw StoreError.http(response.statusCode, "raw.githubusercontent.com")
        }
        let file: IndexFile
        do { file = try JSONDecoder().decode(IndexFile.self, from: data) }
        catch { throw StoreError.invalid("skills.json is not valid. It should look like { \"skills\": [ { \"id\", \"name\", \"description\", \"version\", \"files\" } ] }.") }
        if let v = file.version, v > 1 { throw StoreError.invalid("This skills store needs a newer version of Satellite.") }
        guard file.skills.count <= SkillLimits.maxSkills else { throw StoreError.invalid("skills.json lists more than \(SkillLimits.maxSkills) skills.") }
        var seen = Set<String>(), entries: [SkillEntry] = []
        for entry in file.skills {
            guard isValidSkillID(entry.id), !seen.contains(entry.id) else { continue }
            try validate(entry)
            seen.insert(entry.id)
            entries.append(entry)
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let etag = response.value(forHTTPHeaderField: "Etag")
        return SkillIndex(source: identifier, revision: etag ?? UUID().uuidString, etag: etag, fetchedAt: Date(), entries: entries)
    }

    func download(_ file: StoreFile, of entry: SkillEntry) async throws -> Data {
        guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("unsafe path") }
        let path = (directory.isEmpty ? "" : directory + "/") + entry.id + "/" + file.path
        let (data, response) = try await fetch(rawURL(path: path), maxBytes: SkillLimits.maxFileSize, headers: [:])
        guard response.statusCode == 200 else { throw StoreError.notFound(file.path) }
        if let sha = file.sha, gitBlobSHA(data) != sha { throw StoreError.verification(file.path) }
        return data
    }

    private func rawURL(path: String) -> URL {
        rawBase.appendingPathComponent(repository).appendingPathComponent(ref)
            .appendingPathComponent(path)
    }

    private func fetch(_ url: URL, maxBytes: Int, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw StoreError.network("no response") }
            guard data.count <= maxBytes else { throw StoreError.tooLarge(url.lastPathComponent) }
            return (data, http)
        } catch let error as StoreError { throw error }
        catch { throw StoreError.network(error.localizedDescription) }
    }

    private func validate(_ entry: SkillEntry) throws {
        guard entry.files.count <= SkillLimits.maxFiles else { throw StoreError.invalid("\(entry.id) has too many files") }
        guard entry.files.contains(where: { $0.path == "SKILL.md" }) else { throw StoreError.invalid("\(entry.id) has no SKILL.md") }
        guard entry.files.allSatisfy({ ExtensionManifest.isSafeRelativePath($0.path) }) else { throw StoreError.invalid("\(entry.id) has an unsafe path") }
        guard entry.totalSize <= SkillLimits.maxTotalSize else { throw StoreError.tooLarge(entry.id) }
    }
}

// MARK: - Local source (tests / local repo)

struct SkillLocalSource: SkillSource {
    let directory: URL
    var identifier: String { "skills-local:" + directory.path }

    func fetchIndex(cached: SkillIndex?) async throws -> SkillIndex {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var entries: [SkillEntry] = [], fingerprint = ""
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = folder.lastPathComponent
            guard isValidSkillID(id), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fm.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
            let files = try listFiles(in: folder)
            let meta = SkillMeta.read(folder.appendingPathComponent("SKILL.md"))
            entries.append(SkillEntry(id: id, name: meta.name ?? id, description: meta.description ?? "",
                                      version: meta.version ?? "1.0.0", files: files))
            fingerprint += files.map { "\(id)/\($0.path)=\($0.sha ?? "")" }.joined()
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SkillIndex(source: identifier, revision: "local-" + String(sha1Hex(fingerprint).prefix(10)), etag: nil, fetchedAt: Date(), entries: entries)
    }

    func download(_ file: StoreFile, of entry: SkillEntry) async throws -> Data {
        guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("unsafe path") }
        let url = directory.appendingPathComponent(entry.id).appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url) else { throw StoreError.notFound(file.path) }
        if let sha = file.sha, gitBlobSHA(data) != sha { throw StoreError.verification(file.path) }
        return data
    }

    private func listFiles(in folder: URL) throws -> [StoreFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        let root = folder.resolvingSymlinksInPath().path + "/"
        var files: [StoreFile] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            files.append(StoreFile(path: String(path.dropFirst(root.count)), sha: gitBlobSHA(try Data(contentsOf: url)), size: values.fileSize ?? 0))
        }
        return files.sorted { $0.path < $1.path }
    }
}

// MARK: - SKILL.md frontmatter

/// The handful of fields Satellite reads from a SKILL.md's YAML frontmatter.
struct SkillMeta {
    var name: String?
    var description: String?
    var version: String?

    static func read(_ url: URL) -> SkillMeta {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return SkillMeta() }
        return parse(text)
    }

    static func parse(_ text: String) -> SkillMeta {
        var meta = SkillMeta()
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return meta }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "name": meta.name = value
            case "description": meta.description = value
            case "version": meta.version = value
            default: break
            }
        }
        return meta
    }
}

// MARK: - Installer

enum SkillInstaller {
    /// Downloads a skill's files into a staging folder, verifies them, then swaps the folder into place in one
    /// move. A failure leaves any installed version untouched.
    static func install(_ entry: SkillEntry, from index: SkillIndex, using source: SkillSource) async throws {
        guard isValidSkillID(entry.id) else { throw StoreError.invalid("Invalid skill id.") }
        let root = AppPaths.skills
        let staging = root.appendingPathComponent(".installing-\(entry.id)-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagingRoot = staging.resolvingSymlinksInPath().path + "/"

        var total = 0
        let downloads = await boundedMap(entry.files) { file -> (StoreFile, Result<Data, Error>) in
            // The await stays in its own statement: with `return (file, .success(try await ...))` the optimized
            // (release) build hands back a corrupted tuple (garbage paths), so files land at junk paths and
            // SKILL.md is never written — exactly the bug ExtensionInstaller hit. Debug builds happen to work.
            do {
                let data = try await source.download(file, of: entry)
                return (file, .success(data))
            } catch {
                return (file, .failure(error))
            }
        }
        for (file, result) in downloads {
            let data = try result.get()
            total += data.count
            guard total <= SkillLimits.maxTotalSize else { throw StoreError.tooLarge(entry.id) }
            guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("Unsafe file path in \(entry.id).") }
            let destination = staging.appendingPathComponent(file.path)
            guard destination.resolvingSymlinksInPath().path.hasPrefix(stagingRoot) else { throw StoreError.invalid("Unsafe file path in \(entry.id).") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        guard fm.fileExists(atPath: staging.appendingPathComponent("SKILL.md").path) else {
            throw StoreError.invalid("\(entry.id) has no SKILL.md.")
        }
        try SkillOrigin(source: index.source, ref: index.revision, version: entry.version, installedAt: Date()).write(to: staging)

        let target = root.appendingPathComponent(entry.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: target) }
    }
}
