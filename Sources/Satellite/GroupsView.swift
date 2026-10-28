import AppKit
import SwiftUI

/// The Groups view, shown in the content area when Groups is selected in the rail: every tab group, whether its
/// pages are loaded, and the ways to make, fill, load, open and import them.
struct GroupsListView: View {
    @ObservedObject var model: AppsModel
    @ObservedObject var groups: SatelliteGroups
    var open: (String) -> Void

    @State private var addingAddress: AddressTarget?
    @State private var renaming: SavedGroup?
    @State private var deleting: SavedGroup?
    @State private var importing = false
    @State private var expanded: Set<String> = []

    private var apps: [WebApp] { model.config.apps.filter { !$0.isTerminal } }
    private var saved: [SavedGroup] { model.config.groups ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tab Groups").font(.title2.weight(.semibold))
                    Text("Pages from any app or address, kept together. Load a group to open its pages in the background, ready for you (or an agent, through Satellite\u{2019}s MCP server) without switching to it; Open shows it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Import from Chrome\u{2026}") { importing = true }
                newGroupMenu
            }
            .padding(20)
            Divider()
            if saved.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "square.grid.2x2").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No tab groups yet").font(.headline)
                    Text("Make one from an app or an address, or right-click any tab and choose Add to Group.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    newGroupMenu.padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                List {
                    ForEach(saved) { group in
                        GroupRow(group: group, apps: apps, groups: groups,
                                 expanded: Binding(get: { expanded.contains(group.id) },
                                                   set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }),
                                 open: { open(group.id) },
                                 addAddress: { addingAddress = .group(group.id) },
                                 rename: { renaming = group },
                                 delete: { deleting = group })
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $addingAddress) { target in
            AddressSheet(title: target == .newGroup ? "New Group from an Address" : "Add an Address") { member in
                switch target {
                case .newGroup: groups.create(name: member.name, members: [member])
                case .group(let id): groups.add(member, to: id)
                }
            }
        }
        .sheet(item: $renaming) { group in
            RenameSheet(name: group.name) { groups.rename(group.id, to: $0) }
        }
        .sheet(isPresented: $importing) {
            ChromeImportSheet { found in
                groups.create(name: "From Chrome", color: .gray,
                              members: found.map { GroupMember(name: $0.url.host ?? $0.url.absoluteString, url: $0.url) })
            }
        }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { group in
            Button("Delete Group", role: .destructive) { groups.delete(group.id) }
        } message: { _ in
            Text("Its pages close and the group is removed. The apps its pages came from aren\u{2019}t affected.")
        }
    }

    private var newGroupMenu: some View {
        Menu {
            Menu("From App") {
                ForEach(apps) { app in
                    Button(app.name) { groups.create(name: app.name, members: [SatelliteGroups.member(from: app)]) }
                }
            }
            Button("From Address\u{2026}") { addingAddress = .newGroup }
            Divider()
            Button("Empty Group") { groups.create(name: "New Group", members: []) }
        } label: {
            Label("New Group", systemImage: "plus")
        }
        .fixedSize()
    }
}

enum AddressTarget: Identifiable, Equatable {
    case newGroup
    case group(String)

    var id: String {
        switch self {
        case .newGroup: return "new"
        case .group(let id): return id
        }
    }
}

/// One group in the list: its color and name, what's in it, whether it's loaded, and its actions. Expanding it
/// lists its pages, each with whether it's loaded and a button to take it out.
private struct GroupRow: View {
    let group: SavedGroup
    let apps: [WebApp]
    @ObservedObject var groups: SatelliteGroups
    @Binding var expanded: Bool
    var open: () -> Void
    var addAddress: () -> Void
    var rename: () -> Void
    var delete: () -> Void

    private var isLoaded: Bool { groups.isLoaded(group.id) }
    private var loadedCount: Int { groups.loadedCount(group.id) }
    private var isEmpty: Bool { group.members.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide its pages" : "Show its pages")

                Circle().fill(Color(nsColor: group.color.nsColor)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                status
                if isLoaded {
                    if loadedCount < group.members.count {
                        Button("Load") { groups.load(group.id) }.help("Load the pages whose tabs were closed")
                    }
                    Button("Unload") { groups.unload(group.id) }.help("Close its pages; the group stays")
                } else {
                    Button("Load") { groups.load(group.id) }
                        .disabled(isEmpty)
                        .help("Open its pages in the background, without switching to them")
                }
                Button("Open", action: open)
                    .disabled(isEmpty)
                    .help("Show this group")
                menu
            }
            if expanded { members.padding(.leading, 34) }
        }
        .padding(.vertical, 6)
        .contextMenu { menuItems }
    }

    private var summary: String {
        guard !isEmpty else { return "No pages yet" }
        let count = group.members.count == 1 ? "1 page" : "\(group.members.count) pages"
        return "\(count) \u{00B7} " + group.members.map(\.name).joined(separator: ", ")
    }

    /// Green when every page is loaded, orange when some are, gray when none.
    private var status: some View {
        let (color, text): (Color, String) = {
            guard isLoaded else { return (.secondary, "Not loaded") }
            if loadedCount < group.members.count { return (.orange, "\(loadedCount) of \(group.members.count) loaded") }
            return (.green, "Loaded")
        }()
        return HStack(spacing: 5) {
            Circle().fill(isLoaded ? color : .clear).overlay(Circle().stroke(color, lineWidth: 1)).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(color == .secondary ? .secondary : color)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var menu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
    }

    @ViewBuilder private var menuItems: some View {
        Menu("Add App") {
            ForEach(apps) { app in
                Button(app.name) { groups.add(SatelliteGroups.member(from: app), to: group.id) }
            }
        }
        Button("Add Address\u{2026}", action: addAddress)
        Divider()
        Button("Rename\u{2026}", action: rename)
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { color in
                Button { groups.recolor(group.id, to: color) } label: {
                    if color == group.color { Label(color.label, systemImage: "checkmark") } else { Text(color.label) }
                }
            }
        }
        Divider()
        Button("Delete Group\u{2026}", role: .destructive, action: delete)
    }

    @ViewBuilder private var members: some View {
        if isEmpty {
            HStack(spacing: 8) {
                Text("No pages yet.").foregroundStyle(.secondary)
                Menu("Add") { menuItems }.fixedSize()
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.members) { member in
                    HStack(spacing: 8) {
                        SymbolImage(name: apps.first { $0.id == member.appID }?.symbol ?? "globe", size: 12).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name).lineLimit(1)
                            Text(member.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if isLoaded {
                            let present = groups.loaded[group.id]?.tabs.contains { $0.groupMemberID == member.id } == true
                            Text(present ? "Loaded" : "Not loaded").font(.caption2).foregroundStyle(present ? .green : .secondary)
                        }
                        Button { groups.remove(memberID: member.id, from: group.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Take this page out of the group")
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Asks for an address (and optionally a name) for a group's new page.
private struct AddressSheet: View {
    let title: String
    var add: (GroupMember) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Address", text: $address, prompt: Text(verbatim: "https://example.com/")).textFieldStyle(.roundedBorder)
            TextField("Name", text: $name, prompt: Text("Optional; the site\u{2019}s name if left empty")).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        do {
            let url = try AppsModel.address(from: address)
            let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            add(GroupMember(name: typed.isEmpty ? (url.host ?? url.absoluteString) : typed, url: url))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RenameSheet: View {
    @State var name: String
    var save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { save(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Scans Chrome's session files for the pages it had open and imports the ones you keep as a new group (not
/// loaded until you Load or Open it). See `ChromeImport` for what the scan can and can't tell.
private struct ChromeImportSheet: View {
    var onImport: ([ChromeImport.FoundTab]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = true
    @State private var scanned: [ChromeImport.FoundTab] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import from Chrome").font(.headline)
            Text("Best-effort: scanned Chrome\u{2019}s own session files for URLs that look like open tabs. This can include pages you\u{2019}ve since navigated away from, and never recovers Chrome\u{2019}s tab groups \u{2014} Chrome doesn\u{2019}t expose those here. The ones you keep become a new group, not loaded until you Load or Open it.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if scanning {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scanned.isEmpty {
                    Text("Nothing recognizable was found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(scanned) { tab in
                        Toggle(isOn: Binding(get: { selected.contains(tab.id) },
                                             set: { if $0 { selected.insert(tab.id) } else { selected.remove(tab.id) } })) {
                            Text(tab.url.absoluteString).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 260)
            HStack {
                if !scanned.isEmpty {
                    Button(selected.count == scanned.count ? "Select None" : "Select All") {
                        selected = selected.count == scanned.count ? [] : Set(scanned.map(\.id))
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) Page\(selected.count == 1 ? "" : "s")") {
                    onImport(scanned.filter { selected.contains($0.id) })
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .task {
            let result = await Task.detached(priority: .userInitiated) { ChromeImport.scanRecentSessionFiles() }.value
            scanned = result
            selected = Set(result.map(\.id))
            scanning = false
        }
    }
}
