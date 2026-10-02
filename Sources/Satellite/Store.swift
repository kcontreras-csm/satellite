import CryptoKit
import Foundation

// MARK: - Index types

struct StoreFile: Codable, Hashable {
    /// Path relative to the extension folder.
    var path: String
    /// Git blob SHA-1 of the content when the source knows it; downloads are verified against it.
    var sha: String?
    /// Size in bytes, or 0 when unknown until downloaded.
    var size: Int
}

/// Where an extension's folder lives: a repository, a branch/tag/commit, and the folder inside it.
struct StoreLocation: Codable, Hashable {
    var repository: String
    var ref: String
    var path: String
}

struct StoreEntry: Codable, Hashable, Identifiable {
    var manifest: ExtensionManifest
    var files: [StoreFile]
    var location: StoreLocation?
    /// ETag of manifest.json, so unchanged manifests aren't downloaded again.
    var etag: String?

    var id: String { manifest.id }
    var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    func file(_ path: String) -> StoreFile? { files.first { $0.path == path } }
}

struct StoreIssue: Codable, Hashable {
    var folder: String
    var message: String
}

struct StoreIndex: Codable {
    /// Identifies where the index came from, e.g. "owner/repo". Recorded in installed extensions.
    var source: String
    /// Changes whenever any listed extension or version changes.
    var revision: String
    /// ETag of the extensions.json file.
    var etag: String?
    var fetchedAt: Date
    var entries: [StoreEntry]
    /// Folders that look like extensions but were rejected (bad manifest, too large, ...).
    var issues: [StoreIssue]
}

enum StoreLimits {
    static let maxFilesPerExtension = 200
    static let maxFileSize = 2_000_000
    static let maxTotalSize = 10_000_000
}

enum StoreError: LocalizedError {
    case indexNotFound(String)
    case notFound(String)
    case rateLimited
    case http(Int, String)
    case network(String)
    case tooLarge(String)
    case invalidConfig(String)
    case verification(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .indexNotFound(let url): return "No extensions.json was found at \(url)."
        case .notFound(let what): return "\(what) was not found."
        case .rateLimited: return "GitHub is limiting requests from this network right now. Try again in a few minutes."
        case .http(let code, let host): return "Unexpected response (\(code)) from \(host)."
        case .network(let message): return "Network problem: \(message)"
        case .tooLarge(let what): return "\(what) is larger than Satellite allows."
        case .invalidConfig(let message): return "Invalid store settings: \(message)"
        case .verification(let path): return "\u{201C}\(path)\u{201D} did not match its published checksum, so it was not installed."
        case .invalid(let message): return message
        }
    }
}

// MARK: - Source

protocol StoreSource {
    /// Stable name used for cache files and recorded as the install origin.
    var identifier: String { get }
    /// Returns a fresh index, or `cached` when nothing changed upstream.
    func fetchIndex(cached: StoreIndex?) async throws -> StoreIndex
    /// Downloads one file of an entry, checked against `file.sha` when there is one.
    func download(_ file: StoreFile, of entry: StoreEntry) async throws -> Data
}

enum StoreSourceFactory {
    /// `SATELLITE_STORE_DIR` points the store at a local folder of extensions (handy while developing one).
    /// Otherwise the store reads `extensions.json` from the configured GitHub repository.
    static func make(_ config: StoreConfig) -> StoreSource {
        if let path = ProcessInfo.processInfo.environment["SATELLITE_STORE_DIR"], !path.isEmpty {
            return LocalSource(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return GitHubSource(config: config)
    }
}

// MARK: - Helpers shared by sources

func gitBlobSHA(_ data: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(data.count)\0".utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func sha1Hex(_ text: String) -> String {
    Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Checks an extension's file list against the limits and that the files its manifest needs are present.
func validateStoreEntryFiles(_ manifest: ExtensionManifest, files: [StoreFile]) throws {
    guard files.count <= StoreLimits.maxFilesPerExtension else {
        throw StoreError.invalid("has more than \(StoreLimits.maxFilesPerExtension) files")
    }
    guard files.allSatisfy({ ExtensionManifest.isSafeRelativePath($0.path) }) else {
        throw StoreError.invalid("contains an unsafe file path")
    }
    guard files.allSatisfy({ $0.size <= StoreLimits.maxFileSize }) else {
        throw StoreError.invalid("contains a file larger than \(StoreLimits.maxFileSize / 1_000_000) MB")
    }
    guard files.reduce(0, { $0 + $1.size }) <= StoreLimits.maxTotalSize else {
        throw StoreError.invalid("is larger than \(StoreLimits.maxTotalSize / 1_000_000) MB in total")
    }
    let present = Set(files.map(\.path))
    for path in manifest.codeFiles where !present.contains(path) {
        throw StoreError.invalid("references \u{201C}\(path)\u{201D}, which is not in the folder")
    }
}

/// Runs `work` over `items` with a bounded number in flight, preserving input order in the result.
func boundedMap<Item, Result>(_ items: [Item], limit: Int = 8,
                              _ work: @escaping (Item) async -> Result) async -> [Result] {
    await withTaskGroup(of: (Int, Result).self) { group in
        var results = [Result?](repeating: nil, count: items.count)
        var next = 0
        func enqueue() {
            guard next < items.count else { return }
            let index = next, item = items[next]
            next += 1
            group.addTask { (index, await work(item)) }
        }
        for _ in 0..<min(limit, items.count) { enqueue() }
        while let (index, result) = await group.next() {
            results[index] = result
            enqueue()
        }
        return results.compactMap { $0 }
    }
}

// MARK: - Local source

/// Reads extensions from `<directory>/<id>/manifest.json`. Used for development and tests.
struct LocalSource: StoreSource {
    let directory: URL
    var identifier: String { "local:\(directory.path)" }

    func fetchIndex(cached: StoreIndex?) async throws -> StoreIndex {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            throw StoreError.notFound("The folder \(directory.path)")
        }
        var entries: [StoreEntry] = []
        var issues: [StoreIssue] = []
        var fingerprint = ""

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = folder.lastPathComponent
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !id.hasPrefix("_"), fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { continue }
            do {
                let files = try listFiles(in: folder)
                guard let manifestFile = files.first(where: { $0.path == "manifest.json" }) else { continue }
                let data = try Data(contentsOf: folder.appendingPathComponent(manifestFile.path))
                let manifest = try ExtensionManifest.parse(data, folderName: id)
                try validateStoreEntryFiles(manifest, files: files)
                entries.append(StoreEntry(manifest: manifest, files: files, location: nil, etag: nil))
                fingerprint += files.map { "\(id)/\($0.path)=\($0.sha ?? "")" }.joined(separator: "\n")
            } catch {
                issues.append(StoreIssue(folder: id, message: error.localizedDescription))
            }
        }
        entries.sort { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        return StoreIndex(
            source: identifier, revision: "local-" + String(sha1Hex(fingerprint).prefix(10)), etag: nil,
            fetchedAt: Date(), entries: entries, issues: issues)
    }

    func download(_ file: StoreFile, of entry: StoreEntry) async throws -> Data {
        guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("unsafe path") }
        let url = directory.appendingPathComponent(entry.id).appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url) else { throw StoreError.notFound(file.path) }
        if let sha = file.sha, gitBlobSHA(data) != sha { throw StoreError.verification(file.path) }
        return data
    }

    private func listFiles(in folder: URL) throws -> [StoreFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let root = folder.resolvingSymlinksInPath().path + "/"
        var files: [StoreFile] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let size = values.fileSize ?? 0
            guard size <= StoreLimits.maxFileSize else { throw StoreError.invalid("contains a file larger than \(StoreLimits.maxFileSize / 1_000_000) MB") }
            files.append(StoreFile(path: String(path.dropFirst(root.count)), sha: gitBlobSHA(try Data(contentsOf: url)), size: size))
        }
        return files.sorted { $0.path < $1.path }
    }
}

// MARK: - Cache

enum StoreCache {
    private static var directory: URL { AppPaths.storeCache }

    private static func indexURL(_ source: String) -> URL {
        directory.appendingPathComponent("index-\(sha1Hex(source)).json")
    }

    static func loadIndex(source: String) -> StoreIndex? {
        guard let data = try? Data(contentsOf: indexURL(source)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoreIndex.self, from: data)
    }

    static func save(_ index: StoreIndex) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL(index.source), options: .atomic)
    }

    private static func iconURL(_ sha: String) -> URL? {
        guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }) else { return nil }
        let dir = directory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(sha)
    }

    static func icon(sha: String) -> Data? {
        iconURL(sha).flatMap { try? Data(contentsOf: $0) }
    }

    static func saveIcon(_ data: Data, sha: String) {
        if let url = iconURL(sha) { try? data.write(to: url, options: .atomic) }
    }
}
