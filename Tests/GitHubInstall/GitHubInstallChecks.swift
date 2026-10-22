import Foundation

// Stand-ins for the WebKit side of the app, which these checks don't compile.
struct ExtensionInfo { let id: String; var manifest: ExtensionManifest? }
enum MatchPattern { static func regexSource(_ pattern: String) throws -> String { pattern } }

@main
struct GitHubInstallChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ what: String) {
        if condition { print("PASS: \(what)") } else { failures += 1; print("FAIL: \(what)") }
    }

    static func fails<T>(_ what: String, containing text: String, _ body: () async throws -> T) async {
        do { _ = try await body(); check(false, "\(what) (it succeeded)") }
        catch { check(error.localizedDescription.contains(text), "\(what) \u{2014} \u{201C}\(error.localizedDescription)\u{201D}") }
    }

    static func commit(_ n: Int) -> String { String(format: "%040x", n) }

    static func main() async throws {
        let server = ProcessInfo.processInfo.environment["FAKE_GITHUB"]!   // http://127.0.0.1:<port>
        addresses()
        refs()
        origins()
        try await lookups(server: server)
        try await installs(server: server)
        print(failures == 0 ? "\nAll GitHub-install checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Pure

    static func addresses() {
        func parsed(_ input: String) -> GitHubAddress? { try? GitHubAddress.parse(input) }
        check(parsed("acme/single") == GitHubAddress(repository: "acme/single", ref: .defaultBranch, path: ""), "owner/name is the repository root on the default branch")
        check(parsed("  acme/single/sub/ext@v1.0.0 ") == GitHubAddress(repository: "acme/single", ref: .named("v1.0.0"), path: "sub/ext"), "owner/name/folder@ref shorthand")
        check(parsed("https://github.com/acme/single.git") == GitHubAddress(repository: "acme/single", ref: .defaultBranch, path: ""), ".git suffix")
        check(parsed("git@github.com:acme/single.git")?.repository == "acme/single", "SSH clone address")
        check(parsed("github.com/acme/single/")?.repository == "acme/single", "link without https://")
        check(parsed("https://github.com/acme/single/tree/feature/login/sub/ext?tab=readme#top")?.ref == .refThenPath(["feature", "login", "sub", "ext"]), "/tree/ link keeps ref and folder together until refs are known; query and fragment dropped")
        check(parsed("https://github.com/acme/single/blob/main/sub/ext/manifest.json")?.ref == .refThenPath(["main", "sub", "ext"]), "/blob/ link to a file installs its folder")
        check(parsed("https://raw.githubusercontent.com/acme/single/main/sub/ext/manifest.json")?.ref == .refThenPath(["main", "sub", "ext"]), "raw.githubusercontent.com link")
        check(parsed("https://github.com/acme/single/releases/tag/v1.0.0")?.ref == .named("v1.0.0"), "release link means that tag")
        check(parsed("https://github.com/acme/single/commit/\(commit(0x51))")?.ref == .named(commit(0x51)), "commit link means that commit")

        for (input, message) in [
            ("", "Paste a GitHub address"),
            ("https://gitlab.com/acme/single", "Only github.com"),
            ("https://github.com/acme", "needs to include the repository"),
            ("https://github.com/acme/single/issues/3", "Link to the repository or to a folder"),
            ("acme/single/../../etc", "isn\u{2019}t a folder inside the repository"),
            ("acme/single@", "Add a branch or tag"),
            ("acme", "owner/repository"),
            ("acme/bad name", "isn\u{2019}t a GitHub repository name"),
        ] {
            do { _ = try GitHubAddress.parse(input); check(false, "rejects \u{201C}\(input)\u{201D}") }
            catch { check(error.localizedDescription.contains(message), "rejects \u{201C}\(input)\u{201D} \u{2014} \(error.localizedDescription)") }
        }
    }

    static func refs() {
        // What github.com actually sent for the store repository (captured), as pkt-lines.
        let captured = "001e# service=git-upload-pack\n0000"
            + "0159" + "3ed70a40414cfaaf036a99f8f04f9ec311cbf9eb HEAD\0multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed allow-tip-sha1-in-want allow-reachable-sha1-in-want no-done symref=HEAD:refs/heads/main filter object-format=sha1 agent=git/github-f6e509caf74d-Linux\n"
            + "003d3ed70a40414cfaaf036a99f8f04f9ec311cbf9eb refs/heads/main\n0000"
        let parsed = GitRefs.parse(Data(captured.utf8))
        check(parsed == ["HEAD": "3ed70a40414cfaaf036a99f8f04f9ec311cbf9eb", "refs/heads/main": "3ed70a40414cfaaf036a99f8f04f9ec311cbf9eb"], "parses GitHub's real refs advertisement (capabilities and service line ignored)")
        check(GitRefs.parse(Data("zzzz garbage".utf8)).isEmpty && GitRefs.parse(Data("00ff0123".utf8)).isEmpty, "malformed or truncated data gives no refs instead of crashing")

        let table = ["HEAD": commit(1), "refs/heads/main": commit(1), "refs/heads/v2": commit(2),
                     "refs/tags/v2": commit(9), "refs/tags/v2^{}": commit(3), "refs/heads/feature/login": commit(4)]
        check(GitRefs.commit(for: "v2", in: table) == commit(3), "a tag beats a branch of the same name, and an annotated tag resolves to its commit")
        check(GitRefs.commit(for: "refs/heads/v2", in: table) == commit(2), "a full ref name picks exactly that ref")

        let tree = GitHubAddress(repository: "acme/single", ref: .refThenPath(["feature", "login", "sub", "ext"]), path: "")
        let resolved = try? tree.resolve(refs: table)
        check(resolved?.requestedRef == "feature/login" && resolved?.path == "sub/ext" && resolved?.commit == commit(4), "a /tree/ link with a branch containing \u{201C}/\u{201D} splits at the longest known branch")
        let short = GitHubAddress(repository: "acme/single", ref: .named("3ed70a4"), path: "")
        do { _ = try short.resolve(refs: table); check(false, "shortened commit is refused") }
        catch { check(error.localizedDescription.contains("full 40-character commit"), "a shortened commit gets a clear message") }
    }

    static func origins() {
        let old = #"{"source":"kcontreras-csm/satellite-extensions","ref":"HEAD","installedVersion":"1.0.0","installedAt":"2026-10-01T10:00:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(ExtensionOrigin.self, from: Data(old.utf8))
        check(decoded != nil && decoded?.isFromGitHubAddress == false && decoded?.githubAddress == nil, "origin files written before this change still read, as store installs")

        let github = ExtensionOrigin(source: "acme/single", ref: commit(0x53), installedVersion: "0.3.0", installedAt: Date(),
                                     channel: .github, path: "sub/ext", requestedRef: "feature/login")
        check(github.githubAddress == "acme/single/sub/ext@feature/login", "update check re-reads the same folder on the branch that was asked for, not the old commit")
        check(github.githubURL?.absoluteString == "https://github.com/acme/single/tree/\(commit(0x53))/sub/ext", "source link points at the installed commit")
        let root = ExtensionOrigin(source: "acme/single", ref: commit(0x51), installedVersion: "1.0.0", installedAt: Date(), channel: .github, path: "", requestedRef: nil)
        check(root.githubAddress == "acme/single", "default branch at the root is just owner/name")
        check((try? GitHubAddress.parse(github.githubAddress!)) == GitHubAddress(repository: "acme/single", ref: .named("feature/login"), path: "sub/ext"), "the recorded address parses back to the same place")
    }

    // MARK: Against the fake GitHub

    static func lookups(server: String) async throws {
        let single = try await GitHubLookup.lookUp("acme/single")
        let s1 = single.found.first
        check(!single.isCollection && s1?.id == "single" && s1?.entry.manifest.version == "1.0.0", "a repository with a root manifest.json is one extension, id from the repository name")
        check(single.commit == commit(0x51) && s1?.entry.location?.ref == commit(0x51) && s1?.requestedRef == nil, "pinned to the commit main points at; requested ref recorded as the default branch")

        let tagged = try await GitHubLookup.lookUp("https://github.com/acme/single/releases/tag/v1.0.0")
        check(tagged.commit == commit(0x51) && tagged.requestedRef == "v1.0.0", "an annotated tag resolves through to its commit")

        let nested = try await GitHubLookup.lookUp("https://github.com/acme/single/tree/feature/login/sub/ext")
        check(nested.found.first?.id == "sub-ext" && nested.path == "sub/ext" && nested.commit == commit(0x53) && nested.requestedRef == "feature/login", "folder on a branch whose name contains \u{201C}/\u{201D}; id from the manifest")

        let mixed = try await GitHubLookup.lookUp("https://github.com/Acme/Mixed_Case")
        check(mixed.found.first?.id == "mixed_case", "a repository name with capitals becomes a lowercase id")

        let collection = try await GitHubLookup.lookUp("acme/collection")
        let ids = Set(collection.found.map(\.id))
        check(collection.isCollection && ids == ["greeter", "shared-lib", "remote-thing", "other-default"], "an extensions.json at the address is a collection to choose from \u{2014} \(ids.sorted())")
        check(collection.found("greeter")?.requestedRef == nil && collection.found("remote-thing")?.requestedRef == "main" && collection.found("other-default")?.requestedRef == nil,
              "each entry tracks the right branch for updates: the collection\u{2019}s, the item\u{2019}s own, or the other repository\u{2019}s default")
        check(collection.found("other-default")?.entry.location == StoreLocation(repository: "acme/single", ref: commit(0x51), path: "extras/other"),
              "an item in another repository that names no ref reads that repository\u{2019}s default branch, not the collection\u{2019}s commit")
        check(collection.issues.contains { $0.folder == "broken" }, "a listed folder that can't be read is reported, not fatal")
        check(collection.found.allSatisfy { GitRefs.isCommitID($0.commit) }, "every collection entry is pinned to a commit\u{2026}")
        check(collection.found("remote-thing")?.entry.location == StoreLocation(repository: "acme/single", ref: commit(0x51), path: "extras/remote"), "\u{2026}including one that lives in another repository at a branch")

        // A single folder whose manifest needs a library: found beside it, in the same repository at the same commit.
        let inCollection = try await GitHubLookup.lookUp("https://github.com/acme/collection/tree/main/greeter")
        let viaIndex = StorePlanner.plan(installing: inCollection.found[0].entry, index: inCollection.planningIndex(store: nil), installed: [])
        check(!inCollection.isCollection && inCollection.libraries.map(\.id) == ["shared-lib"] && viaIndex.canInstall && viaIndex.steps.map(\.id) == ["shared-lib", "greeter"],
              "a folder inside a collection gets its library from the collection\u{2019}s extensions.json (not offered as a choice)")
        let plain = try await GitHubLookup.lookUp("acme/plain/app")
        let viaSibling = StorePlanner.plan(installing: plain.found[0].entry, index: plain.planningIndex(store: nil), installed: [])
        check(plain.libraries.map(\.id) == ["util"] && plain.libraries[0].commit == commit(0x51) && viaSibling.canInstall,
              "without an extensions.json, a library in a sibling folder named after the dependency is used")
        let alone = try await GitHubLookup.lookUp("acme/single")
        check(alone.libraries.isEmpty, "no dependency, no extra reads")

        await fails("unknown or private repository", containing: "Only public repositories") { try await GitHubLookup.lookUp("acme/nope") }
        await fails("unknown branch", containing: "no branch or tag named \u{201C}nobranch\u{201D}") { try await GitHubLookup.lookUp("acme/single@nobranch") }
        await fails("folder with neither file", containing: "no manifest.json or extensions.json in acme/single/docs") { try await GitHubLookup.lookUp("acme/single/docs") }
        await fails("a name that can't be an id", containing: "Add an \u{201C}id\u{201D} to manifest.json") { try await GitHubLookup.lookUp("acme/_underscore") }
    }

    static func installs(server: String) async throws {
        let github = GitHubSource(config: .default)
        func installed(_ id: String) -> (ExtensionManifest?, ExtensionOrigin?) {
            let folder = AppPaths.extensions.appendingPathComponent(id)
            let manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))).flatMap { try? ExtensionManifest.parse($0, folderName: id) }
            return (manifest, ExtensionOrigin.read(from: folder))
        }
        func post(_ path: String) async throws { var r = URLRequest(url: URL(string: server + path)!); r.httpMethod = "POST"; _ = try await URLSession.shared.data(for: r) }

        // Review v1, then someone pushes v2 to main before Install is clicked.
        let reviewed = try await GitHubLookup.lookUp("acme/single")
        try await post("/__move?repo=acme/single&ref=refs/heads/main&to=\(commit(0x52))")
        let found = reviewed.found[0]
        try await ExtensionInstaller.installFromGitHub(found.entry, requestedRef: found.requestedRef, using: github)
        let (manifest, origin) = installed("single")
        let code = try? String(contentsOf: AppPaths.extensions.appendingPathComponent("single/content.js"), encoding: .utf8)
        check(manifest?.version == "1.0.0" && code == "console.log('single v1')", "installs exactly the reviewed commit even though the branch moved meanwhile")
        check(origin?.channel == .github && origin?.ref == commit(0x51) && origin?.source == "acme/single" && origin?.path == "" && origin?.requestedRef == nil, "records GitHub as the channel, the commit, folder and requested ref")

        let log = String(decoding: try await URLSession.shared.data(from: URL(string: server + "/__log")!).0, as: UTF8.self)
        let raw = log.split(separator: "\n")
        check(!raw.isEmpty && raw.allSatisfy { line in line.split(separator: "@")[1].split(separator: ":")[0].count == 40 }, "every file was downloaded at a commit id, never at a branch name (\(raw.count) downloads)")

        var unpinned = found.entry
        unpinned.location?.ref = "main"
        await fails("an entry not pinned to a commit", containing: "isn\u{2019}t pinned to a commit") {
            try await ExtensionInstaller.installFromGitHub(unpinned, requestedRef: nil, using: github)
        }
        check(installed("single").0?.version == "1.0.0", "a refused install leaves the installed version untouched")

        // Check for update: look the recorded address up again.
        let again = try await GitHubLookup.lookUp(origin!.githubAddress!)
        check(again.commit == commit(0x52) && again.found[0].entry.manifest.version == "2.0.0", "looking up the recorded address again finds the new commit")
        try await ExtensionInstaller.installFromGitHub(again.found[0].entry, requestedRef: again.found[0].requestedRef, using: github)
        check(installed("single").0?.version == "2.0.0" && installed("single").1?.ref == commit(0x52), "updating replaces it with the new commit")

        // A collection entry that needs a library from the same collection.
        let collection = try await GitHubLookup.lookUp("acme/collection")
        let greeter = collection.found("greeter")!
        let plan = StorePlanner.plan(installing: greeter.entry, index: collection.planningIndex(store: nil), installed: [])
        check(plan.canInstall && plan.steps.map(\.id) == ["shared-lib", "greeter"], "its library comes from the same collection, installed first")
        for step in plan.steps {
            let item = collection.found(step.id)!
            try await ExtensionInstaller.installFromGitHub(item.entry, requestedRef: item.requestedRef, using: github)
        }
        check(installed("shared-lib").0?.isLibrary == true && installed("greeter").1?.ref == commit(0xC1) && installed("greeter").1?.path == "greeter",
              "both installed, each recording its own folder at the collection\u{2019}s commit")
    }
}
