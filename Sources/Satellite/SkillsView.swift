import SwiftUI

// MARK: - Model

@MainActor
final class SkillStoreModel: ObservableObject {
    static let shared = SkillStoreModel(source: SkillSourceFactory.make(AppConfig.load().effectiveSkillsStore))

    enum Phase: Equatable { case idle, loading, loaded, empty, failed(String) }
    enum Status: Equatable { case available, installed(String), updateAvailable(String), local }

    struct Installed: Identifiable {
        var id: String
        var name: String
        var description: String
        var version: String
        var fromStore: Bool
    }

    @Published private(set) var index: SkillIndex?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var staleReason: String?
    @Published private(set) var installed: [String: Installed] = [:]
    @Published private(set) var busy: [String: String] = [:]
    @Published var alert: String?

    let source: SkillSource
    private var isRefreshing = false

    init(source: SkillSource) {
        self.source = source
        if let cached = SkillStoreCache.load(source: source.identifier) {
            index = cached
            phase = cached.entries.isEmpty ? .empty : .loaded
        }
        scanInstalled()
    }

    var repositoryURL: URL? { (source as? SkillGitHubSource)?.webURL }

    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if index == nil { phase = .loading }
        do {
            let fresh = try await source.fetchIndex(cached: index)
            SkillStoreCache.save(fresh)
            index = fresh
            staleReason = nil
            phase = fresh.entries.isEmpty ? .empty : .loaded
        } catch StoreError.indexNotFound {
            index = nil; phase = .empty
        } catch {
            if let index, !index.entries.isEmpty { staleReason = error.localizedDescription; phase = .loaded }
            else { phase = .failed(error.localizedDescription) }
        }
        scanInstalled()
    }

    func status(of entry: SkillEntry) -> Status {
        guard let have = installed[entry.id] else { return .available }
        guard have.fromStore else { return .local }
        let newer: Bool
        if let a = SemVer(have.version), let b = SemVer(entry.version) { newer = b > a } else { newer = have.version != entry.version }
        return newer ? .updateAvailable(have.version) : .installed(have.version)
    }

    func install(_ entry: SkillEntry) async {
        guard let index, busy[entry.id] == nil else { return }
        busy[entry.id] = "Installing\u{2026}"
        defer { busy[entry.id] = nil }
        do { try await SkillInstaller.install(entry, from: index, using: source); scanInstalled() }
        catch { alert = "Couldn\u{2019}t install \u{201C}\(entry.name)\u{201D}: \(error.localizedDescription)" }
    }

    @Published private(set) var migrating = false

    /// Installs or replaces every store skill in one go — the "migrate all" action. Force-refreshes first so it
    /// always acts on the current repository (not a stale cached list), then installs each skill that isn't
    /// already present and up to date, overwriting local copies and making them store-managed.
    func migrateAll() async {
        await refresh(force: true)
        guard let index, !migrating else { return }
        migrating = true
        defer { migrating = false }
        var failed: [String] = []
        for entry in index.entries {
            if case .installed = status(of: entry) { continue }   // already the current store version
            busy[entry.id] = "Installing\u{2026}"
            do { try await SkillInstaller.install(entry, from: index, using: source) }
            catch { failed.append("\u{201C}\(entry.name)\u{201D}: \(error.localizedDescription)") }
            busy[entry.id] = nil
        }
        scanInstalled()
        if !failed.isEmpty { alert = "Some skills didn\u{2019}t install:\n" + failed.joined(separator: "\n") }
    }

    /// How many store skills aren't yet installed as the current store version (what "migrate all" would act on).
    var pendingCount: Int {
        (index?.entries ?? []).filter { if case .installed = status(of: $0) { return false } else { return true } }.count
    }

    func remove(_ id: String) {
        let folder = AppPaths.skills.appendingPathComponent(id, isDirectory: true)
        do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil); scanInstalled() }
        catch { alert = "Couldn\u{2019}t remove \u{201C}\(id)\u{201D}: \(error.localizedDescription)" }
    }

    /// Store skills that aren't installed yet, plus (for the second section) installed skills not in the store.
    var installedNotInStore: [Installed] {
        let storeIDs = Set(index?.entries.map(\.id) ?? [])
        return installed.values.filter { !storeIDs.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func scanInstalled() {
        let fm = FileManager.default
        var found: [String: Installed] = [:]
        let folders = (try? fm.contentsOfDirectory(at: AppPaths.skills, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for folder in folders {
            let id = folder.lastPathComponent
            guard isValidSkillID(id), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fm.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
            let meta = SkillMeta.read(folder.appendingPathComponent("SKILL.md"))
            let origin = SkillOrigin.read(from: folder)
            found[id] = Installed(id: id, name: meta.name ?? id, description: meta.description ?? "",
                                  version: origin?.version ?? meta.version ?? "", fromStore: origin?.source == source.identifier)
        }
        installed = found
    }
}

enum SkillStoreCache {
    private static func url(_ source: String) -> URL { AppPaths.storeCache.appendingPathComponent("skills-\(sha1Hex(source)).json") }
    static func load(source: String) -> SkillIndex? {
        guard let data = try? Data(contentsOf: url(source)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(SkillIndex.self, from: data)
    }
    static func save(_ index: SkillIndex) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(index) else { return }
        try? data.write(to: url(index.source), options: .atomic)
    }
}

// MARK: - View

struct SkillsView: View {
    @ObservedObject var model = SkillStoreModel.shared
    /// A store skill the user is about to install over an existing local copy with the same id (confirm first,
    /// since it overwrites files that didn't come from the store).
    @State private var replacing: SkillEntry?
    @State private var confirmMigrateAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.refresh() }
        .alert("Skills", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), actions: {
            Button("OK", role: .cancel) { model.alert = nil }
        }, message: { Text(model.alert ?? "") })
        .confirmationDialog("Replace \u{201C}\(replacing?.name ?? "")\u{201D} with the store copy?",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) { if let entry = replacing { replacing = nil; Task { await model.install(entry) } } }
            Button("Cancel", role: .cancel) { replacing = nil }
        } message: {
            Text("A skill with this id is already in ~/.claude/skills and wasn\u{2019}t installed from this store. Replacing overwrites it with the store\u{2019}s version; any local changes are lost.")
        }
        .confirmationDialog("Install or replace all \(model.pendingCount) skill(s) from the store?",
                            isPresented: $confirmMigrateAll, titleVisibility: .visible) {
            Button("Migrate all", role: .destructive) { Task { await model.migrateAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Installs every store skill into ~/.claude/skills. Any copy of the same skill already there is overwritten with the store\u{2019}s version and becomes store-managed (so it updates from the store from now on).")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code skills").font(.headline)
                Text("Installed into ~/.claude/skills, where Claude Code finds them.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.migrating {
                ProgressView().controlSize(.small)
            } else if model.pendingCount > 0 {
                Button("Migrate all (\(model.pendingCount))") { confirmMigrateAll = true }
                    .help("Install or replace every skill in the store")
            }
            if let url = model.repositoryURL {
                Link("Repository", destination: url).font(.callout)
            }
            Button {
                Task { await model.refresh(force: true) }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("Check for updates")
            .disabled(model.migrating)
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading, .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder(systemImage: "exclamationmark.triangle", title: "Couldn\u{2019}t load the skills store", detail: message)
        case .empty:
            placeholder(systemImage: "tray", title: "No skills published", detail: "The repository has no skills.json, or it lists no skills.")
        case .loaded:
            List {
                if let reason = model.staleReason {
                    Label("Showing a cached list: \(reason)", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                }
                Section("Store") {
                    ForEach(model.index?.entries ?? []) { entry in row(entry) }
                }
                let extras = model.installedNotInStore
                if !extras.isEmpty {
                    Section("Installed, not from this store") {
                        ForEach(extras) { skill in extraRow(skill) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: SkillEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action(entry)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func action(_ entry: SkillEntry) -> some View {
        if let note = model.busy[entry.id] {
            Text(note).font(.caption).foregroundStyle(.secondary)
        } else {
            switch model.status(of: entry) {
            case .available:
                Button("Install") { Task { await model.install(entry) } }
            case .installed:
                HStack(spacing: 8) {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Button("Remove", role: .destructive) { model.remove(entry.id) }
                }
            case .updateAvailable(let from):
                HStack(spacing: 8) {
                    Button("Update") { Task { await model.install(entry) } }
                    Text("from v\(from)").font(.caption).foregroundStyle(.secondary)
                }
            case .local:
                HStack(spacing: 8) {
                    Text("Installed, not from the store").font(.caption).foregroundStyle(.orange)
                    Button("Replace with store copy") { replacing = entry }
                }
            }
        }
    }

    private func extraRow(_ skill: SkillStoreModel.Installed) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).fontWeight(.medium)
                if !skill.description.isEmpty { Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Button("Remove", role: .destructive) { model.remove(skill.id) }
        }
        .padding(.vertical, 2)
    }

    private func placeholder(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
