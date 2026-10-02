import AppKit
import SwiftUI

// MARK: - Icon

/// Shows an extension's icon: an image file, an SF Symbol, or (when none is given or loading fails)
/// a generated monogram whose color is derived from the extension id.
struct ExtensionIconView: View {
    let id: String
    let name: String
    let spec: ExtensionIconSpec
    var size: CGFloat = 40
    var load: () async -> NSImage? = { nil }

    @State private var image: NSImage?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.quaternary))
            .task(id: id + "|" + String(describing: spec)) {
                if case .file = spec { image = await load() } else { image = nil }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch spec {
        case .symbol(let symbol) where NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil:
            ZStack {
                gradient
                Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white)
            }
        case .file where image != nil:
            Image(nsImage: image!).resizable().scaledToFit().padding(size * 0.06).background(.background)
        default:
            ZStack {
                gradient
                Text(String(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"))
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
    }

    private var gradient: some View {
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hue = Double(hash % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.88), Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.68)],
            startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Store tab

struct StoreView: View {
    @ObservedObject var store: StoreModel
    @ObservedObject var manager: ExtensionManager
    @Binding var detail: StoreEntry?

    @State private var query = ""
    @State private var category = "All"

    private var categories: [String] {
        ["All"] + Set((store.index?.entries ?? []).compactMap { $0.manifest.category }).sorted()
    }

    private var visible: [StoreEntry] {
        let entries = store.index?.entries ?? []
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return entries.filter { entry in
            let m = entry.manifest
            if category != "All" && m.category != category { return false }
            let haystack = ([m.id, m.name, m.description, m.author.name, m.category ?? ""] + m.keywords).joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search extensions", text: $query).textFieldStyle(.roundedBorder)
                if categories.count > 2 {
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                Button {
                    Task { await store.refresh(force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the store")
                    .disabled(store.phase == .loading)
            }

            if let stale = store.staleReason {
                Label("Showing the last downloaded list. \(stale)", systemImage: "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(.orange)
            }

            switch store.phase {
            case .idle, .loading:
                ProgressView("Loading the store\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyState
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("Can\u{2019}t reach the store").font(.headline)
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await store.refresh(force: true) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if visible.isEmpty {
                    Text("No extensions match \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visible) { entry in
                        StoreRow(entry: entry, store: store, manager: manager) { detail = entry }
                    }
                }
                footer
            }
        }
        .task { await store.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
            Text("The store is empty").font(.headline)
            Text("No extensions have been published yet. Add an extensions.json that lists them to the repository, then refresh.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let detail = store.emptyDetail {
                Text("Looked for \(detail)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            if let url = store.repositoryURL { Link("Open the repository", destination: url) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        if let index = store.index {
            VStack(alignment: .leading, spacing: 4) {
                if !index.issues.isEmpty {
                    DisclosureGroup("\(index.issues.count) folder\(index.issues.count == 1 ? " was" : "s were") skipped") {
                        ForEach(index.issues, id: \.folder) { issue in
                            Text("\(issue.folder): \(issue.message)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
                Text("\(index.source) \u{00B7} \(index.entries.count) extension\(index.entries.count == 1 ? "" : "s") \u{00B7} checked \(index.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct StoreRow: View {
    let entry: StoreEntry
    @ObservedObject var store: StoreModel
    @ObservedObject var manager: ExtensionManager
    let open: () -> Void

    var body: some View {
        let m = entry.manifest
        HStack(alignment: .top, spacing: 12) {
            ExtensionIconView(id: m.id, name: m.name, spec: m.iconSpec, size: 44) { await store.icon(for: entry) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.name).font(.headline)
                    Text("v\(m.version)").foregroundStyle(.secondary)
                    if m.isLibrary { Tag(text: "Library") }
                }
                Text("by \(m.author.name)").font(.caption).foregroundStyle(.secondary)
                Text(m.description).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !m.dependencies.isEmpty {
                    Text("Requires " + m.dependencyRanges.map { "\($0.id) \($0.range)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    @ViewBuilder private var action: some View {
        if let progress = store.busy[entry.id] {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(progress).font(.caption) }
        } else {
            switch store.status(of: entry) {
            case .available: Button("Get", action: open).buttonStyle(.borderedProminent)
            case .updateAvailable: Button("Update", action: open).buttonStyle(.borderedProminent)
            case .installed(let version): Label("Installed \(version.description)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .localCopy: Button("Replace\u{2026}", action: open)
            case .incompatible(let reason): Text(reason).font(.caption).foregroundStyle(.red).frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Detail sheet

struct StoreDetailSheet: View {
    let entry: StoreEntry
    @ObservedObject var store: StoreModel
    @ObservedObject var manager: ExtensionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = entry.manifest
        let plan = store.plan(for: entry)
        let status = store.status(of: entry)

        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        ExtensionIconView(id: m.id, name: m.name, spec: m.iconSpec, size: 64) { await store.icon(for: entry) }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(m.name).font(.title2.bold())
                                Text("v\(m.version)").foregroundStyle(.secondary)
                            }
                            Text("by \(m.author.name)").foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                if let license = m.license { Text(license) }
                                if let category = m.category { Text(category) }
                                if let home = m.homepageURL { Link("Website", destination: home) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Text(m.description)

                    section("Permissions") {
                        let permissions = plan.permissions
                        if permissions.isEmpty {
                            Text("None. It can\u{2019}t save data, show notifications or open links.").foregroundStyle(.secondary)
                        } else {
                            ForEach(permissions, id: \.self) { Label($0.summary, systemImage: "checkmark.shield") }
                        }
                    }

                    if m.isLibrary {
                        section("Runs on") {
                            Text("Nothing by itself. Other extensions load this library.").foregroundStyle(.secondary)
                        }
                    } else if m.runsOnPages {
                        section("Runs on these pages") {
                            ForEach(m.matches, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                            Text(m.world == "main"
                                 ? "Runs alongside the page\u{2019}s own scripts."
                                 : "Runs isolated from the page\u{2019}s own scripts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if m.background != nil {
                        section("Background") {
                            Text("Runs a script while Satellite is open, with no page needed.").foregroundStyle(.secondary)
                        }
                    }

                    if !m.settings.isEmpty {
                        section("Settings") {
                            Text(m.settings.map(\.title).joined(separator: ", ")).foregroundStyle(.secondary)
                            Text("You can change these after installing.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }

                    if !m.dependencies.isEmpty {
                        section("Dependencies") {
                            ForEach(m.dependencyRanges, id: \.id) { dependency in
                                dependencyLine(dependency.id, dependency.range, plan: plan)
                            }
                        }
                    }

                    if !plan.problems.isEmpty {
                        section("Can\u{2019}t install") {
                            ForEach(plan.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                        }
                    }

                    Text("\(entry.files.count) file\(entry.files.count == 1 ? "" : "s")\(entry.totalSize > 0 ? " \u{00B7} " + ByteCountFormatter.string(fromByteCount: Int64(entry.totalSize), countStyle: .file) : "") \u{00B7} from \(entry.location?.repository ?? store.index?.source ?? "the store")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if case .localCopy(let version) = status {
                    Text("A local copy (\(version.description)) is installed and will be replaced.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                primaryButton(status: status, plan: plan)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder private func primaryButton(status: StoreModel.EntryStatus, plan: InstallPlan) -> some View {
        let others = plan.steps.filter { $0.id != entry.id }.count
        switch status {
        case .installed:
            Button("Installed") {}.disabled(true)
        case .incompatible:
            Button("Unavailable") {}.disabled(true)
        default:
            Button(buttonTitle(status, others: others)) {
                dismiss()
                Task { await store.install(entry) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.canInstall || store.busy[entry.id] != nil)
        }
    }

    private func buttonTitle(_ status: StoreModel.EntryStatus, others: Int) -> String {
        let base: String
        switch status {
        case .updateAvailable: base = "Update"
        case .localCopy: base = "Replace"
        default: base = "Install"
        }
        return others > 0 ? "\(base) with \(others) dependenc\(others == 1 ? "y" : "ies")" : base
    }

    private func dependencyLine(_ id: String, _ range: VersionRange, plan: InstallPlan) -> some View {
        let installed = manager.info(id)
        let step = plan.steps.first { $0.id == id }
        let text: String
        let color: Color
        if let step {
            text = step.isUpdate ? "will be updated to \(step.entry.manifest.version)" : "will be installed (\(step.entry.manifest.version))"
            color = .blue
        } else if let version = installed?.version, range.contains(version) {
            text = "already installed (\(version))"
            color = .green
        } else {
            text = "unavailable"
            color = .red
        }
        return HStack {
            Text("\(id) \(range.text)").font(.system(.body, design: .monospaced))
            Text(text).foregroundStyle(color)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}
