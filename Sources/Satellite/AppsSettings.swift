import AppKit
import SwiftUI

extension WebApp: Identifiable {}

/// The apps of the left rail and the assistants of the right panel, as Settings edits them. The built-in ones
/// (`AppConfig.defaults`) are where everything starts; every change is written to config.json and shown at once.
final class AppsModel: ObservableObject {
    static let shared = AppsModel()

    @Published private(set) var config: AppConfig
    private var checkedFile = false

    init() {
        config = AppConfig.load()
    }

    func items(_ section: SidebarSection) -> [WebApp] {
        section == .apps ? config.apps : config.assistants
    }

    /// The built-in item with this id, if there is one.
    func builtIn(_ section: SidebarSection, id: String) -> WebApp? {
        (section == .apps ? AppConfig.defaults.apps : AppConfig.defaults.assistants).first { $0.id == id }
    }

    /// Built-in items that are no longer in the list (removed, or never there).
    func missingBuiltIns(_ section: SidebarSection) -> [WebApp] {
        let present = Set(items(section).map(\.id))
        return (section == .apps ? AppConfig.defaults.apps : AppConfig.defaults.assistants).filter { !present.contains($0.id) }
    }

    /// Whether the built-in item of this id has been changed.
    func isEdited(_ section: SidebarSection, _ app: WebApp) -> Bool {
        guard let original = builtIn(section, id: app.id) else { return false }
        return original != app
    }

    /// The last app can't be removed: Satellite needs at least one to show.
    func canRemove(_ section: SidebarSection) -> Bool {
        section == .assistants || config.apps.count > 1
    }

    // MARK: Changing

    func move(_ section: SidebarSection, from offsets: IndexSet, to destination: Int) {
        change(section) { $0.move(fromOffsets: offsets, toOffset: destination) }
    }

    /// Moves one item up (negative) or down (positive).
    func move(_ section: SidebarSection, id: String, by offset: Int) {
        change(section) { list in
            guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset) else { return }
            list.insert(list.remove(at: index), at: index + offset)
        }
    }

    /// Replaces the item with the same id, or adds it at the end.
    func save(_ app: WebApp, in section: SidebarSection) {
        change(section) { list in
            if let index = list.firstIndex(where: { $0.id == app.id }) { list[index] = app } else { list.append(app) }
        }
    }

    func remove(_ section: SidebarSection, id: String) {
        guard canRemove(section) else { return }
        change(section) { $0.removeAll { $0.id == id } }
    }

    /// Puts a built-in item back after the built-in items that come before it, or first if none is left.
    func restore(_ app: WebApp, in section: SidebarSection) {
        let order = (section == .apps ? AppConfig.defaults.apps : AppConfig.defaults.assistants).map(\.id)
        change(section) { list in
            guard !list.contains(where: { $0.id == app.id }) else { return }
            let earlier = Set(order.prefix { $0 != app.id })
            let position = list.lastIndex { earlier.contains($0.id) }.map { $0 + 1 } ?? 0
            list.insert(app, at: position)
        }
    }

    /// Back to the built-in apps and assistants. The extension store setting is kept.
    func resetToDefaults() {
        config.apps = AppConfig.defaults.apps
        config.assistants = AppConfig.defaults.assistants
        persist()
    }

    /// An id for a new item: the name in lower case, made unique.
    func uniqueID(for name: String, in section: SidebarSection) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = slug.isEmpty ? "app" : String(slug.prefix(30))
        let taken = Set(items(section).map(\.id))
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    private func change(_ section: SidebarSection, _ edit: (inout [WebApp]) -> Void) {
        switch section {
        case .apps: edit(&config.apps)
        case .assistants: edit(&config.assistants)
        }
        persist()
    }

    private func persist() {
        keepUnreadableFile()
        config.save()
        UIRegistry.shared.configure(config)
    }

    /// If config.json could not be read when Satellite started, it was left alone; the first save would replace it,
    /// so a copy is kept next to it.
    private func keepUnreadableFile() {
        guard !checkedFile else { return }
        checkedFile = true
        guard let data = try? Data(contentsOf: AppPaths.config) else { return }
        if let readable = try? JSONDecoder().decode(AppConfig.self, from: data), !readable.apps.isEmpty { return }
        let copy = AppPaths.config.deletingLastPathComponent().appendingPathComponent("config.invalid.json")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: AppPaths.config, to: copy)
    }

    // MARK: Checking what was typed

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A web address from what was typed: "example.com" becomes https://example.com.
    static func address(from text: String) throws -> URL {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, !typed.contains("://") { typed = "https://" + typed }
        guard let url = URL(string: typed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else {
            throw Problem("Enter a web address, like https://example.com")
        }
        return url
    }

    static func name(from text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count) else { throw Problem("Give it a name of 1\u{2013}40 characters") }
        return name
    }
}

// MARK: - Settings tab

/// Settings > Apps: the left rail and the right panel, each a list to reorder (drag), edit, add to and remove from.
struct AppsSettings: View {
    @ObservedObject var model = AppsModel.shared

    private struct Target: Identifiable {
        let section: SidebarSection
        let app: WebApp?
        var id: String { section.rawValue + ":" + (app?.id ?? "new") }
    }

    @State private var editing: Target?
    @State private var removing: Target?
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    listSection(.apps, title: "Apps", subtitle: "Left sidebar. The first nine have \u{2318}1\u{2013}9.")
                    listSection(.assistants, title: "Assistants", subtitle: "Right panel. The first nine have \u{2325}\u{2318}1\u{2013}9.")
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }

            HStack {
                Menu("Add") {
                    Button("New App\u{2026}") { editing = Target(section: .apps, app: nil) }
                    Button("New Assistant\u{2026}") { editing = Target(section: .assistants, app: nil) }
                    ForEach([SidebarSection.apps, .assistants], id: \.self) { section in
                        let missing = model.missingBuiltIns(section)
                        if !missing.isEmpty {
                            Divider()
                            ForEach(missing, id: \.id) { app in
                                Button("Restore \(app.name)") { model.restore(app, in: section) }
                            }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Text("Drag the grip at the left of a row to reorder it. Changes apply right away.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults\u{2026}") { confirmReset = true }
            }
        }
        .sheet(item: $editing) { target in
            AppEditor(section: target.section, original: target.app, model: model)
        }
        .confirmationDialog(
            "Remove \u{201C}\(removing?.app?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { target in
            Button("Remove", role: .destructive) {
                if let app = target.app { model.remove(target.section, id: app.id) }
            }
        } message: { _ in
            Text("It leaves the sidebar. Your sign-in to the site is kept, and you can add it back.")
        }
        .confirmationDialog("Reset apps and assistants to the defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetToDefaults() }
        } message: {
            Text("The built-in apps and assistants come back in their original order and anything you added leaves the sidebar. Sign-ins are kept.")
        }
    }

    private static let rowHeight: CGFloat = 54

    private func listSection(_ section: SidebarSection, title: String, subtitle: String) -> some View {
        let items = model.items(section)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if items.isEmpty {
                    Text("None. Use Add to bring one in.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                } else {
                    ReorderableColumn(items: items, rowHeight: Self.rowHeight, move: { model.move(section, from: $0, to: $1) }) { app, handle in
                        AppRow(
                            app: app, section: section, model: model, handle: handle,
                            edit: { editing = Target(section: section, app: app) },
                            remove: { removing = Target(section: section, app: app) })
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

private struct AppRow: View {
    let app: WebApp
    let section: SidebarSection
    @ObservedObject var model: AppsModel
    let handle: ReorderHandle
    let edit: () -> Void
    let remove: () -> Void

    private var items: [WebApp] { model.items(section) }
    private var index: Int { items.firstIndex { $0.id == app.id } ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            handle
            HStack(spacing: 10) {
                SymbolImage(name: app.symbol, size: 15).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name)
                        if model.isEdited(section, app) { Tag(text: "Edited") }
                        if app.tabs == true { Tag(text: "Links in tabs") }
                    }
                    Text(app.url.absoluteString)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit")
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove")
                .disabled(!model.canRemove(section))
        }
        .padding(.trailing, 12)
        .contextMenu {
            Button("Edit\u{2026}", action: edit)
            Button("Move Up") { model.move(section, id: app.id, by: -1) }.disabled(index == 0)
            Button("Move Down") { model.move(section, id: app.id, by: 1) }.disabled(index >= items.count - 1)
            Divider()
            Button("Remove\u{2026}", role: .destructive, action: remove).disabled(!model.canRemove(section))
        }
    }
}

/// An SF Symbol, or a globe when the name isn't one (as the sidebar does).
struct SymbolImage: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let known = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        Image(systemName: known ? name : "globe").font(.system(size: size))
    }
}

// MARK: - Editing one item

struct AppEditor: View {
    let section: SidebarSection
    let original: WebApp?
    let model: AppsModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var symbol: String
    @State private var opensLinksInTabs: Bool
    @State private var error: String?
    @State private var choosingSymbol = false

    init(section: SidebarSection, original: WebApp?, model: AppsModel) {
        self.section = section
        self.original = original
        self.model = model
        _name = State(initialValue: original?.name ?? "")
        _address = State(initialValue: original?.url.absoluteString ?? "")
        _symbol = State(initialValue: original?.symbol ?? "globe")
        _opensLinksInTabs = State(initialValue: original?.tabs ?? false)
    }

    private var noun: String { section == .apps ? "App" : "Assistant" }
    private var builtIn: WebApp? { original.flatMap { model.builtIn(section, id: $0.id) } }
    private var symbolIsKnown: Bool { NSImage(systemSymbolName: symbol.trimmingCharacters(in: .whitespaces), accessibilityDescription: nil) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name, prompt: Text("Cases")).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Address") {
                    TextField("", text: $address, prompt: Text(verbatim: "https://example.com/")).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Icon") {
                    HStack(spacing: 8) {
                        SymbolImage(name: symbol.trimmingCharacters(in: .whitespaces), size: 16).frame(width: 24)
                        TextField("", text: $symbol, prompt: Text("SF Symbol name"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose\u{2026}") { choosingSymbol = true }
                            .popover(isPresented: $choosingSymbol) { SymbolPicker(selection: $symbol, done: { choosingSymbol = false }) }
                    }
                }
                if !symbolIsKnown {
                    Text("That isn\u{2019}t an SF Symbol name, so a globe is shown.").font(.caption).foregroundStyle(.orange)
                }
                if section == .apps {
                    Toggle("Open links in new tabs", isOn: $opensLinksInTabs)
                    Text("Links that ask for a new window stay in this app as tabs, even links to other sites. Meant for launchers such as Okta, where each tile opens a different application.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
                if let builtIn, builtIn != currentValue {
                    Button("Restore Default") { apply(builtIn) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520)
        .navigationTitle(original == nil ? "New \(noun)" : "Edit \(noun)")
    }

    /// What the fields hold now, when it is valid.
    private var currentValue: WebApp? {
        guard let original, let url = try? AppsModel.address(from: address), let name = try? AppsModel.name(from: name) else { return nil }
        return WebApp(id: original.id, name: name, url: url, symbol: symbol.trimmingCharacters(in: .whitespaces), tabs: section == .apps && opensLinksInTabs ? true : nil)
    }

    private func apply(_ app: WebApp) {
        name = app.name
        address = app.url.absoluteString
        symbol = app.symbol
        opensLinksInTabs = app.tabs ?? false
        error = nil
    }

    private func save() {
        do {
            let checkedName = try AppsModel.name(from: name)
            let url = try AppsModel.address(from: address)
            let checkedSymbol = symbol.trimmingCharacters(in: .whitespaces)
            let app = WebApp(
                id: original?.id ?? model.uniqueID(for: checkedName, in: section), name: checkedName, url: url,
                symbol: checkedSymbol.isEmpty ? "globe" : checkedSymbol, tabs: section == .apps && opensLinksInTabs ? true : nil)
            model.save(app, in: section)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SymbolPicker: View {
    @Binding var selection: String
    let done: () -> Void

    private static let symbols = [
        "globe", "cloud.fill", "bolt.fill", "person.badge.key.fill", "text.magnifyingglass", "book.fill",
        "envelope.fill", "calendar", "chart.bar.fill", "chart.xyaxis.line", "doc.text.fill", "folder.fill",
        "gearshape.fill", "hammer.fill", "wrench.and.screwdriver.fill", "tray.full.fill", "bubble.left.fill", "phone.fill",
        "cart.fill", "creditcard.fill", "lock.fill", "shield.fill", "server.rack", "terminal.fill",
        "cpu", "network", "map.fill", "house.fill", "star.fill", "heart.fill",
        "flag.fill", "bell.fill", "bookmark.fill", "link", "video.fill", "newspaper.fill",
        "person.2.fill", "ticket.fill", "lifepreserver.fill", "list.bullet.rectangle.fill", "checklist", "sparkle",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 7), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { name in
                Button {
                    selection = name
                    done()
                } label: {
                    Image(systemName: name).font(.system(size: 16)).frame(width: 36, height: 30)
                }
                .buttonStyle(.plain)
                .background(selection == name ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .help(name)
            }
        }
        .padding(12)
    }
}
