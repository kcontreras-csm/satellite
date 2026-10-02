import Foundation

/// Reads the store from a GitHub repository without using the GitHub API (no token, no API rate limit).
///
/// The repository holds an `extensions.json` that lists the extensions and where each one's folder lives:
///
///     { "extensions": [
///         { "id": "hello-badge" },
///         { "id": "other", "repository": "someone/else", "ref": "v1.2.0", "path": "extensions/other" } ] }
///
/// `path` defaults to the id, `repository` to this repository and `ref` to the configured branch. Everything is
/// fetched as plain files from raw.githubusercontent.com: the index, then each extension's manifest.json, then
/// (on install) the files that manifest names.
struct GitHubSource: StoreSource {
    let repository: String
    let ref: String
    let directory: String
    private let rawBase: URL

    var identifier: String { repository }
    var webURL: URL? { URL(string: "https://github.com/\(repository)") }

    static let maxIndexSize = 262_144
    static let maxManifestSize = 262_144
    static let maxExtensions = 200

    init(config: StoreConfig) {
        repository = config.repository
        ref = config.branch ?? "HEAD"
        directory = (config.directory ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let env = ProcessInfo.processInfo.environment
        rawBase = URL(string: env["SATELLITE_GITHUB_RAW"] ?? "https://raw.githubusercontent.com")!
    }

    private struct IndexFile: Decodable {
        struct Item: Decodable {
            let id: String
            let path: String?
            let repository: String?
            let ref: String?
        }
        let version: Int?
        let extensions: [Item]
    }

    // MARK: Index

    func fetchIndex(cached: StoreIndex?) async throws -> StoreIndex {
        try Self.validate(repository: repository, ref: ref)
        if !directory.isEmpty, !ExtensionManifest.isSafeRelativePath(directory) {
            throw StoreError.invalidConfig("\u{201C}directory\u{201D} must be a relative path")
        }

        // 1. The list of extensions. A 304 means it is unchanged, so the cached list of places is reused.
        let indexPath = directory.isEmpty ? "extensions.json" : directory + "/extensions.json"
        let indexURL = rawURL(repository: repository, ref: ref, path: indexPath)
        var headers: [String: String] = [:]
        if let etag = cached?.etag, cached?.source == identifier, !(cached?.entries.isEmpty ?? true) { headers["If-None-Match"] = etag }
        let (indexData, indexResponse) = try await fetch(indexURL, maxBytes: Self.maxIndexSize, headers: headers)

        var items: [(id: String, location: StoreLocation)] = []
        var issues: [StoreIssue] = []
        if indexResponse.statusCode == 304, let cached {
            items = cached.entries.compactMap { entry in entry.location.map { (entry.id, $0) } }
        } else {
            try check(indexResponse, what: "extensions.json", indexNotFound: indexURL.absoluteString)
            let file: IndexFile
            do { file = try JSONDecoder().decode(IndexFile.self, from: indexData) }
            catch { throw StoreError.invalid("extensions.json is not valid. It should look like { \"extensions\": [ { \"id\": \"my-extension\" } ] }.") }
            if let version = file.version, version > 1 {
                throw StoreError.invalid("This store needs a newer version of Satellite.")
            }
            guard file.extensions.count <= Self.maxExtensions else {
                throw StoreError.invalid("extensions.json lists more than \(Self.maxExtensions) extensions.")
            }
            var seen = Set<String>()
            for item in file.extensions {
                do {
                    guard ExtensionManifest.isValidID(item.id) else { throw StoreError.invalid("\u{201C}\(item.id)\u{201D} is not a valid extension id.") }
                    guard seen.insert(item.id).inserted else { throw StoreError.invalid("listed twice.") }
                    let itemRepository = item.repository ?? repository
                    let itemRef = item.ref ?? ref
                    let defaultPath = (item.repository == nil && !directory.isEmpty) ? directory + "/" + item.id : item.id
                    let path = item.path ?? defaultPath
                    try Self.validate(repository: itemRepository, ref: itemRef)
                    guard ExtensionManifest.isSafeRelativePath(path) else { throw StoreError.invalid("\u{201C}path\u{201D} must be a relative folder path.") }
                    items.append((item.id, StoreLocation(repository: itemRepository, ref: itemRef, path: path)))
                } catch {
                    issues.append(StoreIssue(folder: item.id, message: error.localizedDescription))
                }
            }
        }

        // 2. Each extension's manifest, reusing the cached one when GitHub says it hasn't changed.
        let previous = Dictionary(cached?.entries.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let outcomes = await boundedMap(items) { item -> (String, Result<StoreEntry, Error>) in
            // Same shape as the installer's downloads: keep the await out of the returned tuple (see there).
            do {
                let entry = try await self.loadEntry(id: item.id, location: item.location, previous: previous[item.id])
                return (item.id, .success(entry))
            } catch {
                return (item.id, .failure(error))
            }
        }

        var entries: [StoreEntry] = []
        for (id, outcome) in outcomes {
            switch outcome {
            case .success(let entry): entries.append(entry)
            case .failure(let error): issues.append(StoreIssue(folder: id, message: error.localizedDescription))
            }
        }
        entries.sort { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        let revision = sha1Hex(entries.map { "\($0.id)@\($0.manifest.version)" }.joined(separator: ","))
        return StoreIndex(
            source: identifier, revision: revision, etag: indexResponse.value(forHTTPHeaderField: "ETag") ?? cached?.etag,
            fetchedAt: Date(), entries: entries, issues: issues)
    }

    private func loadEntry(id: String, location: StoreLocation, previous: StoreEntry?) async throws -> StoreEntry {
        let url = rawURL(repository: location.repository, ref: location.ref, path: location.path + "/manifest.json")
        var headers: [String: String] = [:]
        if let previous, previous.location == location, let etag = previous.etag { headers["If-None-Match"] = etag }

        let (data, response) = try await fetch(url, maxBytes: Self.maxManifestSize, headers: headers)
        if response.statusCode == 304, let previous { return previous }
        try check(response, what: "manifest.json in \(location.path)", indexNotFound: nil)

        let manifest = try ExtensionManifest.parse(data, folderName: id)
        var paths = ["manifest.json"]
        for path in manifest.referencedFiles where !paths.contains(path) { paths.append(path) }
        let files = paths.map { StoreFile(path: $0, sha: nil, size: 0) }
        try validateStoreEntryFiles(manifest, files: files)
        return StoreEntry(manifest: manifest, files: files, location: location, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    func download(_ file: StoreFile, of entry: StoreEntry) async throws -> Data {
        guard let location = entry.location else { throw StoreError.invalid("This extension has no download location.") }
        guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("Refusing to download an unsafe path.") }
        try Self.validate(repository: location.repository, ref: location.ref)

        let url = rawURL(repository: location.repository, ref: location.ref, path: location.path + "/" + file.path)
        let (data, response) = try await fetch(url, maxBytes: StoreLimits.maxFileSize)
        try check(response, what: "\u{201C}\(file.path)\u{201D}", indexNotFound: nil)
        if let sha = file.sha, gitBlobSHA(data) != sha { throw StoreError.verification(file.path) }
        return data
    }

    // MARK: Networking

    private func rawURL(repository: String, ref: String, path: String) -> URL {
        var url = rawBase
        for component in repository.split(separator: "/") + [Substring(ref)] + path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func fetch(_ url: URL, maxBytes: Int, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Satellite/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await BoundedFetch.run(request, maxBytes: maxBytes)
    }

    private func check(_ response: HTTPURLResponse, what: String, indexNotFound url: String?) throws {
        switch response.statusCode {
        case 200..<300: return
        case 404:
            if let url { throw StoreError.indexNotFound(url) }
            throw StoreError.notFound(what)
        case 429: throw StoreError.rateLimited
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0": throw StoreError.rateLimited
        default: throw StoreError.http(response.statusCode, response.url?.host ?? "GitHub")
        }
    }

    // MARK: Validation

    static func validate(repository: String, ref: String) throws {
        let nameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(nameChars.contains) && $0 != "." && $0 != ".." }) else {
            throw StoreError.invalidConfig("\u{201C}repository\u{201D} must look like owner/name")
        }
        guard !ref.isEmpty, ref.count <= 100, !ref.contains(".."), ref.unicodeScalars.allSatisfy(nameChars.contains) else {
            throw StoreError.invalidConfig("\u{201C}branch\u{201D} can use letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} and \u{201C}_\u{201D} only")
        }
    }
}

/// Downloads one URL, giving up as soon as more than `maxBytes` arrive instead of buffering the rest.
private final class BoundedFetch: NSObject, URLSessionDataDelegate {
    private static let session = URLSession(configuration: .ephemeral)

    private let maxBytes: Int
    private var received = Data()
    private var response: HTTPURLResponse?
    private var exceeded = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    private init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    static func run(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let fetcher = BoundedFetch(maxBytes: maxBytes)
        return try await withCheckedThrowingContinuation { continuation in
            fetcher.continuation = continuation
            let task = session.dataTask(with: request)
            task.delegate = fetcher
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maxBytes) {
            exceeded = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
        if received.count > maxBytes {
            exceeded = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if exceeded {
            continuation.resume(throwing: StoreError.tooLarge(task.originalRequest?.url?.lastPathComponent ?? "A file"))
        } else if let error {
            continuation.resume(throwing: StoreError.network(error.localizedDescription))
        } else if let response {
            continuation.resume(returning: (received, response))
        } else {
            continuation.resume(throwing: StoreError.network("no response"))
        }
    }
}
