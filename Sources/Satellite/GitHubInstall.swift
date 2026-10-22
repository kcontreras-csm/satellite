import Foundation

// Installing an extension straight from a GitHub address, outside the store: parse what was pasted, pin the branch
// or tag to the commit it points at right now, and read the extension (or the extensions.json collection) there.
// Pinning means what the user reviews is exactly what gets installed, and the install records an immutable commit.

// MARK: - Addresses

/// Something pasted or typed to install from: a github.com link, or owner/name shorthand.
///
///     owner/name                                  the repository's root, default branch
///     owner/name/folder/inside@v1.2.0             a folder, at a branch or tag
///     https://github.com/owner/name               (also .git, git@github.com:owner/name.git)
///     https://github.com/owner/name/tree/main/folder
///     https://github.com/owner/name/blob/main/folder/manifest.json
///     https://github.com/owner/name/releases/tag/v1.2.0   (also /commit/<full commit>)
///     https://raw.githubusercontent.com/owner/name/main/folder/manifest.json
struct GitHubAddress: Equatable {
    enum Ref: Equatable {
        case defaultBranch
        case named(String)
        /// From a /tree/ or /blob/ link: a branch or tag (which may itself contain "/") followed by the folder.
        /// Which segments are the ref is only known once the repository's refs are read.
        case refThenPath([String])
    }

    var repository: String
    var ref: Ref
    /// The folder inside the repository, "" for its root. Empty for `.refThenPath`, whose folder follows the ref.
    var path: String

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ input: String) throws -> GitHubAddress {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Invalid(message: "Paste a GitHub address, or type owner/repository.") }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }

        if text.hasPrefix("git@github.com:") { text = "https://github.com/" + text.dropFirst("git@github.com:".count) }
        if !text.contains("://"), text.hasPrefix("github.com/") || text.hasPrefix("raw.githubusercontent.com/") || text.hasPrefix("www.github.com/") {
            text = "https://" + text
        }

        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased() else {
                throw Invalid(message: "That isn\u{2019}t a link Satellite understands.")
            }
            var segments = url.path.split(separator: "/").map(String.init)
            switch host {
            case "github.com", "www.github.com":
                guard segments.count >= 2 else { throw Invalid(message: "The link needs to include the repository, like github.com/owner/name.") }
                let repository = try repositoryName(segments[0], segments[1])
                segments.removeFirst(2)
                guard let kind = segments.first else { return GitHubAddress(repository: repository, ref: .defaultBranch, path: "") }
                if kind == "commit", segments.count == 2 { return GitHubAddress(repository: repository, ref: .named(segments[1]), path: "") }
                if kind == "releases", segments.count >= 3, segments[1] == "tag" {
                    return GitHubAddress(repository: repository, ref: .named(segments.dropFirst(2).joined(separator: "/")), path: "")
                }
                guard kind == "tree" || kind == "blob", segments.count >= 2 else {
                    throw Invalid(message: "Link to the repository or to a folder in it (a \u{201C}/tree/\u{2026}\u{201D} link).")
                }
                var rest = Array(segments.dropFirst())
                if kind == "blob" { rest.removeLast() }   // a link to a file: its folder is what is installed
                guard !rest.isEmpty else { throw Invalid(message: "The link is missing its branch or tag.") }
                return GitHubAddress(repository: repository, ref: .refThenPath(rest), path: "")
            case "raw.githubusercontent.com":
                guard segments.count >= 4 else { throw Invalid(message: "Link to a file inside the repository, like its manifest.json.") }
                let repository = try repositoryName(segments[0], segments[1])
                return GitHubAddress(repository: repository, ref: .refThenPath(Array(segments.dropFirst(2).dropLast())), path: "")
            default:
                throw Invalid(message: "Only github.com addresses are supported (not \(host)).")
            }
        }

        // owner/name[/folder][@ref]
        var ref = Ref.defaultBranch
        if let at = text.lastIndex(of: "@") {
            let name = String(text[text.index(after: at)...])
            guard !name.isEmpty else { throw Invalid(message: "Add a branch or tag after \u{201C}@\u{201D}, or leave it out for the default branch.") }
            ref = .named(name)
            text = String(text[..<at])
        }
        let segments = text.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { throw Invalid(message: "Type it as owner/repository, or paste a github.com link.") }
        let path = segments.dropFirst(2).joined(separator: "/")
        try checkPath(path)
        return GitHubAddress(repository: try repositoryName(segments[0], segments[1]), ref: ref, path: path)
    }

    private static func repositoryName(_ owner: String, _ name: String) throws -> String {
        let name = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        let repository = owner + "/" + name
        do { try GitHubSource.validate(repository: repository, ref: "HEAD") }
        catch { throw Invalid(message: "\u{201C}\(repository)\u{201D} isn\u{2019}t a GitHub repository name.") }
        return repository
    }

    static func checkPath(_ path: String) throws {
        guard path.isEmpty || (ExtensionManifest.isSafeRelativePath(path) && !path.split(separator: "/").contains("..")) else {
            throw Invalid(message: "\u{201C}\(path)\u{201D} isn\u{2019}t a folder inside the repository.")
        }
    }

    /// Settles the ref and folder against the repository's refs. A /tree/ link takes the longest leading run of
    /// segments that names a branch or tag, as GitHub does, so a branch like feature/login still works.
    func resolve(refs: [String: String]) throws -> (requestedRef: String?, commit: String, path: String) {
        switch ref {
        case .defaultBranch:
            guard let commit = GitRefs.commit(for: "HEAD", in: refs) else { throw Invalid(message: "\(repository) has no default branch.") }
            return (nil, commit, path)
        case .named(let name):
            if GitRefs.isCommitID(name) { return (name.lowercased(), name.lowercased(), path) }
            guard let commit = GitRefs.commit(for: name, in: refs) else { throw Self.unknownRef(name, repository) }
            return (name, commit, path)
        case .refThenPath(let segments):
            if let first = segments.first, GitRefs.isCommitID(first) {
                let folder = segments.dropFirst().joined(separator: "/")
                try Self.checkPath(folder)
                return (first.lowercased(), first.lowercased(), folder)
            }
            for count in stride(from: segments.count, through: 1, by: -1) {
                let name = segments.prefix(count).joined(separator: "/")
                guard let commit = GitRefs.commit(for: name, in: refs) else { continue }
                let folder = segments.dropFirst(count).joined(separator: "/")
                try Self.checkPath(folder)
                return (name, commit, folder)
            }
            throw Self.unknownRef(segments[0], repository)
        }
    }

    private static func unknownRef(_ name: String, _ repository: String) -> Invalid {
        if name.count < 40, name.allSatisfy(\.isHexDigit) {
            return Invalid(message: "\u{201C}\(name)\u{201D} looks like a shortened commit. Use the full 40-character commit, or a branch or tag.")
        }
        return Invalid(message: "\(repository) has no branch or tag named \u{201C}\(name)\u{201D}.")
    }
}

// MARK: - Git refs

/// The refs a git server advertises at `info/refs?service=git-upload-pack` (protocol v0): pkt-lines of
/// "<commit> <name>", the first followed by NUL and the server's capabilities.
enum GitRefs {
    static func isCommitID(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }

    /// Ref name -> commit, e.g. "HEAD", "refs/heads/main", "refs/tags/v1.0^{}" (an annotated tag's commit).
    static func parse(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var refs: [String: String] = [:]
        var at = 0
        while at + 4 <= bytes.count {
            guard let length = Int(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16) else { break }
            if length < 4 { at += 4; continue }   // flush and delimiter packets
            guard at + length <= bytes.count else { break }
            var line = String(decoding: bytes[at + 4..<at + length], as: UTF8.self)
            at += length
            if let nul = line.firstIndex(of: "\0") { line = String(line[..<nul]) }
            let parts = line.trimmingCharacters(in: .newlines).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, isCommitID(parts[0]) else { continue }   // also skips "# service=..."
            refs[parts[1]] = parts[0].lowercased()
        }
        return refs
    }

    /// The commit a branch or tag points at. Tags win over branches of the same name, as in git itself.
    static func commit(for name: String, in refs: [String: String]) -> String? {
        if name == "HEAD" { return refs["HEAD"] }
        if name.hasPrefix("refs/") { return refs[name + "^{}"] ?? refs[name] }
        return refs["refs/tags/\(name)^{}"] ?? refs["refs/tags/\(name)"] ?? refs["refs/heads/\(name)"]
    }
}

// MARK: - Lookup

enum GitHubLookup {
    /// One extension found at an address, pinned to a commit.
    struct Found: Identifiable {
        var entry: StoreEntry
        /// What to read again when checking for an update: the branch or tag, nil for the default branch.
        var requestedRef: String?
        var id: String { entry.id }
        var commit: String { entry.location?.ref ?? "" }
    }

    struct Result {
        /// The repository the address named.
        var repository: String
        /// The commit the address resolved to.
        var commit: String
        /// The branch or tag that was asked for; nil for the default branch.
        var requestedRef: String?
        var path: String
        /// True when the address held an extensions.json listing several extensions rather than one manifest.json.
        var isCollection: Bool
        var found: [Found]
        /// Libraries from the same repository that the found extension may need. Not offered as choices.
        var libraries: [Found] = []
        /// Collection folders that couldn't be read.
        var issues: [StoreIssue]

        func found(_ id: String) -> Found? { found.first { $0.id == id } }

        /// Anything this lookup can install: a found extension, or a library one of them needs.
        func installable(_ id: String) -> Found? { found(id) ?? libraries.first { $0.id == id } }

        /// What to plan an install against: libraries come from this lookup first (a collection that ships its own,
        /// or the repository the extension lives in), then from the store.
        func planningIndex(store: StoreIndex?) -> StoreIndex {
            var ids = Set(found.map(\.id))
            let extra = libraries.filter { ids.insert($0.id).inserted }
            let fromStore = (store?.entries ?? []).filter { !ids.contains($0.id) }
            return StoreIndex(source: repository, revision: commit, etag: nil, fetchedAt: Date(),
                              entries: found.map(\.entry) + extra.map(\.entry) + fromStore, issues: [])
        }
    }

    /// Reads what is at `input`: a folder with a manifest.json, or a folder with an extensions.json. Everything
    /// returned is pinned to a commit.
    static func lookUp(_ input: String, using source: GitHubSource = GitHubSource(config: .default)) async throws -> Result {
        let address = try GitHubAddress.parse(input)
        let repository = address.repository
        let refs = try await source.refs(of: repository)
        let (requestedRef, commit, path) = try address.resolve(refs: refs)
        let here = StoreLocation(repository: repository, ref: commit, path: path)
        let fallbackID = (path.isEmpty ? String(repository.split(separator: "/")[1]) : String(path.split(separator: "/").last!)).lowercased()

        if let entry = try await source.standaloneEntry(at: here, fallbackID: fallbackID) {
            let libraries = entry.manifest.dependencyRanges.isEmpty || path.isEmpty ? []
                : await nearbyLibraries(for: entry, repository: repository, refs: refs, commit: commit, requestedRef: requestedRef, folder: path, source: source)
            return Result(repository: repository, commit: commit, requestedRef: requestedRef, path: path, isCollection: false,
                          found: [Found(entry: entry, requestedRef: requestedRef)], libraries: libraries, issues: [])
        }

        guard let listed = try await collection(repository: repository, refs: refs, commit: commit, requestedRef: requestedRef, path: path, source: source) else {
            let place = path.isEmpty ? repository : "\(repository)/\(path)"
            throw StoreError.invalid("There is no manifest.json or extensions.json in \(place) (at \(requestedRef ?? "the default branch")).")
        }
        guard !listed.found.isEmpty else {
            throw StoreError.invalid(listed.issues.isEmpty ? "The extensions.json there lists no extensions."
                                                           : "None of the extensions listed there could be read: " + listed.issues.map { "\($0.folder): \($0.message)" }.joined(separator: "; "))
        }
        return Result(repository: repository, commit: commit, requestedRef: requestedRef, path: path, isCollection: true,
                      found: listed.found, issues: listed.issues)
    }

    /// The extensions listed in the extensions.json in `path`, laid out like the store; nil when there is none. Items
    /// may live in other repositories or name their own branch: each is pinned to a commit before its manifest is read.
    private static func collection(repository: String, refs: [String: String], commit: String, requestedRef: String?,
                                   path: String, source: GitHubSource) async throws -> (found: [Found], issues: [StoreIssue])? {
        let pinner = CommitPinner(source: source, known: [repository: refs], collection: (repository, commit), inheritedRef: requestedRef ?? "HEAD")
        var collection = GitHubSource(config: StoreConfig(repository: repository, branch: commit, directory: path.isEmpty ? nil : path))
        collection.pin = { try await pinner.pin($0) }
        let index: StoreIndex
        do {
            index = try await collection.fetchIndex(cached: nil)
        } catch StoreError.indexNotFound(_) {
            return nil
        }

        var found: [Found] = []
        for entry in index.entries {
            guard let location = entry.location else { continue }
            // What to read again for an update: the ref the item named, else (at the collection's own commit) the ref
            // the address named.
            let pinned = await pinner.pinnedFrom(location)
            let inherited = location.repository == repository && location.ref == commit
            found.append(Found(entry: entry, requestedRef: pinned.pinned ? pinned.ref : (inherited ? requestedRef : location.ref)))
        }
        return (found, index.issues)
    }

    /// Libraries an extension in `folder` may need from its own repository, at the same commit: the ones listed in
    /// the parent folder's extensions.json, else sibling folders named after its dependencies. Best effort: what
    /// isn't found here comes from the store, or the install plan says it is missing.
    private static func nearbyLibraries(for entry: StoreEntry, repository: String, refs: [String: String], commit: String,
                                        requestedRef: String?, folder: String, source: GitHubSource) async -> [Found] {
        let parent = folder.split(separator: "/").dropLast().joined(separator: "/")
        if let listed = try? await collection(repository: repository, refs: refs, commit: commit, requestedRef: requestedRef, path: parent, source: source) {
            return listed.found.filter { $0.entry.manifest.isLibrary && $0.id != entry.id }
        }
        var libraries: [Found] = []
        for id in entry.manifest.dependencyRanges.map(\.id) {
            let location = StoreLocation(repository: repository, ref: commit, path: parent.isEmpty ? id : parent + "/" + id)
            if let library = try? await source.standaloneEntry(at: location, fallbackID: id), library.id == id, library.manifest.isLibrary {
                libraries.append(Found(entry: library, requestedRef: requestedRef))
            }
        }
        return libraries
    }
}

/// Pins branches and tags to commits during one lookup, reading each repository's refs once.
actor CommitPinner {
    private let source: GitHubSource
    private var refs: [String: [String: String]]
    private let collection: (repository: String, commit: String)
    private let inheritedRef: String
    /// Pinned location -> the branch or tag it was pinned from; nil value for the default branch.
    private var asked: [StoreLocation: String?] = [:]

    /// `collection` is the repository and commit the extensions.json was read at. An item in another repository that
    /// names no ref inherits that commit from the index, which means nothing there; like the store, it reads at the
    /// branch the address asked for instead (`inheritedRef`).
    init(source: GitHubSource, known: [String: [String: String]], collection: (repository: String, commit: String), inheritedRef: String) {
        self.source = source
        refs = known
        self.collection = collection
        self.inheritedRef = inheritedRef
    }

    func pin(_ location: StoreLocation) async throws -> StoreLocation {
        var location = location
        if location.ref == collection.commit, location.repository != collection.repository { location.ref = inheritedRef }
        if GitRefs.isCommitID(location.ref) { return location }
        if refs[location.repository] == nil { refs[location.repository] = try await source.refs(of: location.repository) }
        guard let commit = GitRefs.commit(for: location.ref, in: refs[location.repository] ?? [:]) else {
            throw StoreError.invalid("\(location.repository) has no branch or tag named \u{201C}\(location.ref)\u{201D}.")
        }
        let pinned = StoreLocation(repository: location.repository, ref: commit, path: location.path)
        asked[pinned] = location.ref == "HEAD" ? .some(nil) : location.ref
        return pinned
    }

    /// Whether this lookup pinned `location`, and from which branch or tag (nil for the default branch).
    func pinnedFrom(_ location: StoreLocation) -> (pinned: Bool, ref: String?) {
        guard let ref = asked[location] else { return (false, nil) }
        return (true, ref)
    }
}
