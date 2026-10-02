import AppKit
import Combine

@MainActor
final class StoreModel: ObservableObject {
    static let shared = StoreModel(source: StoreSourceFactory.make(AppConfig.load().effectiveStore), manager: .shared)

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    enum EntryStatus: Equatable {
        case available
        case installed(SemVer)
        case updateAvailable(from: SemVer)
        /// An extension with this id exists but was not installed from the store.
        case localCopy(SemVer)
        case incompatible(String)
    }

    @Published private(set) var index: StoreIndex?
    @Published private(set) var phase: Phase = .idle
    /// Set when a refresh failed but an older cached list is still being shown.
    @Published private(set) var staleReason: String?
    /// For the empty state: the address that was checked for an extensions.json.
    @Published private(set) var emptyDetail: String?
    /// Extension id -> what is happening to it right now.
    @Published private(set) var busy: [String: String] = [:]
    @Published var alertMessage: String?

    let source: StoreSource
    let manager: ExtensionManager
    private var isRefreshing = false
    private var lastCheck: Date?
    private let iconCache = NSCache<NSString, NSImage>()

    init(source: StoreSource, manager: ExtensionManager) {
        self.source = source
        self.manager = manager
        if let cached = StoreCache.loadIndex(source: source.identifier) {
            index = cached
            phase = cached.entries.isEmpty ? .empty : .loaded
        }
    }

    var repositoryURL: URL? { (source as? GitHubSource)?.webURL }

    // MARK: Refresh

    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        if !force, index != nil, let lastCheck, Date().timeIntervalSince(lastCheck) < 300 { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if index == nil { phase = .loading }

        do {
            let fresh = try await source.fetchIndex(cached: index)
            StoreCache.save(fresh)
            index = fresh
            staleReason = nil
            emptyDetail = nil
            phase = fresh.entries.isEmpty ? .empty : .loaded
            lastCheck = Date()
        } catch StoreError.indexNotFound(let url) {
            index = nil
            staleReason = nil
            emptyDetail = url
            phase = .empty
            lastCheck = Date()
        } catch {
            if let index, !index.entries.isEmpty {
                staleReason = error.localizedDescription
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Status

    func status(of entry: StoreEntry) -> EntryStatus {
        if let problem = entry.manifest.compatibilityProblem { return .incompatible(problem) }
        guard let info = manager.info(entry.id), let version = info.version else { return .available }
        if info.origin == nil { return .localCopy(version) }
        return entry.manifest.semver > version ? .updateAvailable(from: version) : .installed(version)
    }

    /// The store's newer version of an installed extension, if any.
    func update(for id: String) -> StoreEntry? {
        guard let entry = index?.entries.first(where: { $0.id == id }) else { return nil }
        if case .updateAvailable = status(of: entry) { return entry }
        return nil
    }

    func plan(for entry: StoreEntry) -> InstallPlan {
        guard let index else { return InstallPlan(steps: [], problems: ["The store list is not loaded."]) }
        return StorePlanner.plan(installing: entry, index: index, installed: manager.extensions)
    }

    // MARK: Actions

    /// Installs run strictly one after another: two installs touching the same folder at once (a double click,
    /// or two extensions sharing a dependency) would corrupt each other.
    private var installTail: Task<Void, Never>?

    func install(_ entry: StoreEntry) async {
        // Already installing or queued (for example a double click): nothing more to do.
        guard busy[entry.id] == nil else { return }
        busy[entry.id] = "Waiting\u{2026}"

        let previous = installTail
        let task = Task { @MainActor in
            await previous?.value
            await self.performInstall(entry)
        }
        installTail = task
        await task.value
        busy[entry.id] = nil
    }

    /// Runs when it is this install's turn, so the plan sees whatever earlier installs just put in place.
    private func performInstall(_ entry: StoreEntry) async {
        guard let index else { return }
        let plan = plan(for: entry)
        guard plan.canInstall else {
            alertMessage = plan.problems.joined(separator: "\n")
            return
        }
        for step in plan.steps { busy[step.id] = step.isUpdate ? "Updating\u{2026}" : "Installing\u{2026}" }
        defer { for step in plan.steps { busy[step.id] = nil } }

        for step in plan.steps {
            do {
                try await ExtensionInstaller.install(step.entry, from: index, using: source)
                manager.reload()
            } catch {
                alertMessage = "Couldn\u{2019}t install \u{201C}\(step.entry.manifest.name)\u{201D}: \(error.localizedDescription)"
                return
            }
        }
    }

    func uninstall(_ id: String) {
        do { try manager.uninstall(id) } catch { alertMessage = error.localizedDescription }
    }

    // MARK: Icons

    func icon(for entry: StoreEntry) async -> NSImage? {
        guard case .file(let path) = entry.manifest.iconSpec, let file = entry.file(path), file.size <= 1_000_000 else { return nil }
        // A new version of the extension gets a new key, so a changed icon is picked up.
        let key = sha1Hex("\(entry.id)@\(entry.manifest.version)/\(path)")
        if let hit = iconCache.object(forKey: key as NSString) { return hit }

        if let data = StoreCache.icon(sha: key), file.sha.map({ gitBlobSHA(data) == $0 }) ?? true, let image = NSImage(data: data) {
            iconCache.setObject(image, forKey: key as NSString)
            return image
        }
        guard let data = try? await source.download(file, of: entry), data.count <= 1_000_000,
              let image = NSImage(data: data) else { return nil }
        StoreCache.saveIcon(data, sha: key)
        iconCache.setObject(image, forKey: key as NSString)
        return image
    }

    func icon(for info: ExtensionInfo) -> NSImage? {
        guard case .file(let path)? = info.manifest?.iconSpec else { return nil }
        let root = info.directory.resolvingSymlinksInPath().path + "/"
        let url = info.directory.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max <= 1_000_000 else { return nil }
        return NSImage(contentsOf: url)
    }
}
