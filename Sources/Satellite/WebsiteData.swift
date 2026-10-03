import SwiftUI
import WebKit

/// The kinds of website data people think in, each a group of WebKit's own data types.
enum WebsiteDataKind: String, CaseIterable, Identifiable {
    case cookies
    case cache
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cookies: return "Cookies"
        case .cache: return "Cache"
        case .storage: return "Site storage"
        }
    }

    var detail: String {
        switch self {
        case .cookies: return "Sign-in sessions. Clearing them signs you out."
        case .cache: return "Stored copies of pages, scripts and images. Safe to clear; you stay signed in."
        case .storage: return "What sites save in the browser: local storage, IndexedDB, service workers."
        }
    }

    /// WebKit's data types that belong to this kind.
    var types: Set<String> {
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let cookies: Set<String> = [WKWebsiteDataTypeCookies]
        let cache: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        switch self {
        case .cookies: return all.intersection(cookies)
        case .cache: return all.intersection(cache)
        case .storage: return all.subtracting(cookies).subtracting(cache)
        }
    }

    static func types(of kinds: Set<WebsiteDataKind>) -> Set<String> {
        kinds.reduce(into: Set<String>()) { $0.formUnion($1.types) }
    }
}

/// The websites Satellite holds data for, and the means to clear it.
@MainActor
final class WebsiteDataModel: ObservableObject {
    struct Site: Identifiable {
        let record: WKWebsiteDataRecord
        let name: String
        let kinds: Set<WebsiteDataKind>
        var id: String { name }
    }

    @Published private(set) var sites: [Site] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private var store: WKWebsiteDataStore { .default() }

    func refresh() async {
        isLoading = true
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        sites = records.map { record in
            Site(record: record, name: record.displayName, kinds: Set(WebsiteDataKind.allCases.filter { !$0.types.isDisjoint(with: record.dataTypes) }))
        }
        .filter { !$0.kinds.isEmpty }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    /// Clears the chosen kinds of data for one site.
    func clear(_ site: Site, kinds: Set<WebsiteDataKind>) async {
        await store.removeData(ofTypes: WebsiteDataKind.types(of: kinds), for: [site.record])
        message = "Cleared \(Self.describe(kinds)) for \(site.name)."
        await refresh()
    }

    /// Clears the chosen kinds of data for every site.
    func clearEverything(kinds: Set<WebsiteDataKind>) async {
        await store.removeData(ofTypes: WebsiteDataKind.types(of: kinds), modifiedSince: .distantPast)
        message = "Cleared \(Self.describe(kinds)) for all sites."
        await refresh()
    }

    static func describe(_ kinds: Set<WebsiteDataKind>) -> String {
        let names = WebsiteDataKind.allCases.filter(kinds.contains).map { $0.title.lowercased() }
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

/// Settings > General > Website data > Manage: pick what to clear, then clear one site or everything.
struct WebsiteDataSheet: View {
    let reloadPages: () -> Void

    @StateObject private var model = WebsiteDataModel()
    @Environment(\.dismiss) private var dismiss
    @State private var kinds = Set(WebsiteDataKind.allCases)
    @State private var query = ""
    @State private var reloadAfterwards = true
    @State private var confirmEverything = false

    private var shown: [WebsiteDataModel.Site] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? model.sites : model.sites.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Website data").font(.title3.bold())
                Text("Choose what to clear, then clear a single site or everything. Clearing only the cache keeps you signed in.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    ForEach(WebsiteDataKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { kinds.contains(kind) },
                            set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }))
                            .toggleStyle(.checkbox)
                            .help(kind.detail)
                    }
                    Spacer()
                    TextField("Search sites", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            .padding(16)
            Divider()

            if model.isLoading && model.sites.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(model.sites.isEmpty ? "No website data is stored." : "No sites match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { site in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(site.name)
                            Text(WebsiteDataKind.allCases.filter(site.kinds.contains).map(\.title).joined(separator: " \u{00B7} "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clear") { clear(site) }
                            .disabled(site.kinds.isDisjoint(with: kinds))
                            .help("Clear \(WebsiteDataModel.describe(kinds)) for \(site.name)")
                    }
                }
            }
            Divider()

            HStack(spacing: 12) {
                Text(model.message ?? "\(model.sites.count) site\(model.sites.count == 1 ? "" : "s")")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Reload open pages afterwards", isOn: $reloadAfterwards).toggleStyle(.checkbox)
                Button("Clear Everything\u{2026}", role: .destructive) { confirmEverything = true }
                    .disabled(kinds.isEmpty || model.sites.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 500)
        .task { await model.refresh() }
        .confirmationDialog("Clear \(WebsiteDataModel.describe(kinds)) for all sites?", isPresented: $confirmEverything) {
            Button(kinds.contains(.cookies) ? "Clear and Sign Out Everywhere" : "Clear", role: .destructive) {
                Task {
                    await model.clearEverything(kinds: kinds)
                    if reloadAfterwards { reloadPages() }
                }
            }
        }
    }

    private func clear(_ site: WebsiteDataModel.Site) {
        Task {
            await model.clear(site, kinds: kinds)
            if reloadAfterwards { reloadPages() }
        }
    }
}
