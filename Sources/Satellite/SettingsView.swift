import AppKit
import SwiftUI
import WebKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    var onReloadPages: (() -> Void)?
    /// The address of the page in front, used to prefill match patterns.
    var currentPageURL: (() -> URL?)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = SettingsView(manager: .shared, store: .shared, reloadPages: { [weak self] in self?.onReloadPages?() })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    enum Tab { case extensions, store, general }

    @ObservedObject var manager: ExtensionManager
    @ObservedObject var store: StoreModel
    let reloadPages: () -> Void

    @State private var tab: Tab
    @State private var detail: StoreEntry?

    init(manager: ExtensionManager, store: StoreModel, reloadPages: @escaping () -> Void, initialTab: Tab = .extensions) {
        self.manager = manager
        self.store = store
        self.reloadPages = reloadPages
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            ExtensionsSettings(manager: manager, store: store, reloadPages: reloadPages, detail: $detail, browseStore: { tab = .store })
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
                .tag(Tab.extensions)
            StoreView(store: store, manager: manager, detail: $detail)
                .tabItem { Label("Store", systemImage: "square.grid.2x2") }
                .tag(Tab.store)
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .padding(16)
        .frame(width: 800, height: 600)
        .sheet(item: $detail) { entry in
            StoreDetailSheet(entry: entry, store: store, manager: manager)
        }
        .alert("Satellite", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .task { await store.refresh() }
    }
}

// MARK: - Installed extensions

private struct ExtensionsSettings: View {
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var store: StoreModel
    let reloadPages: () -> Void
    @Binding var detail: StoreEntry?
    let browseStore: () -> Void
    @ObservedObject var extensionSettings = ExtensionSettings.shared

    @ObservedObject var logs = ExtensionLog.shared
    @AppStorage(HotReloadDefaults.enabled) private var hotReload = true

    @State private var pendingRemoval: ExtensionInfo?
    @State private var settingsFor: ExtensionInfo?
    @State private var logsFor: ExtensionInfo?
    @State private var creating = false
    @State private var showFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.extensions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No extensions installed").font(.headline)
                    Text("Browse the store, or start your own.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Browse the Store", action: browseStore)
                        Button("New Extension\u{2026}") { creating = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.extensions) { info in
                    ExtensionRow(
                        info: info, store: store,
                        hasSettings: info.error == nil && !manager.settingsSchema(info.id).isEmpty,
                        unreadErrors: logs.unreadErrors[info.id] ?? 0,
                        openSettings: { settingsFor = info },
                        openLogs: { logsFor = info },
                        openEditor: { CodeEditor.open(info.directory) },
                        setEnabled: { manager.setEnabled(info.id, $0) },
                        update: { detail = $0 },
                        remove: { pendingRemoval = info })
                }
            }

            ForEach(manager.conflicts, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }

            HStack {
                Toggle("Reload extensions and their pages when files change", isOn: $hotReload)
                    .onChange(of: hotReload) { _, _ in ExtensionWatcher.shared.restart() }
                Spacer()
                Text("Toggling an extension applies on the next page load.").font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Button("New Extension\u{2026}") { creating = true }
                Button("Folders\u{2026}") { showFolders = true }
                Button("Reveal Folder") { NSWorkspace.shared.open(manager.directory) }
                Button("Rescan") { manager.reload() }
                Spacer()
                Button("Browse Store", action: browseStore)
                Button("Reload Pages", action: reloadPages)
            }
        }
        .sheet(item: $settingsFor) { info in
            ExtensionSettingsSheet(info: info, manager: manager, settings: extensionSettings)
        }
        .sheet(item: $logsFor) { info in
            ExtensionLogSheet(info: info, log: logs)
        }
        .sheet(isPresented: $creating) {
            NewExtensionSheet(manager: manager)
        }
        .sheet(isPresented: $showFolders) {
            DevelopmentFoldersSheet()
        }
        .confirmationDialog(
            "Remove \u{201C}\(pendingRemoval?.displayName ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { info in
            Button("Move to Trash and Delete Its Data", role: .destructive) { store.uninstall(info.id) }
        } message: { _ in
            Text("The folder (\(pendingRemoval?.directory.path ?? "")) goes to the Trash. Its saved data is deleted.")
        }
    }
}

private struct ExtensionRow: View {
    let info: ExtensionInfo
    @ObservedObject var store: StoreModel
    let hasSettings: Bool
    let unreadErrors: Int
    let openSettings: () -> Void
    let openLogs: () -> Void
    let openEditor: () -> Void
    let setEnabled: (Bool) -> Void
    let update: (StoreEntry) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ExtensionIconView(id: info.id, name: info.displayName, spec: info.manifest?.iconSpec ?? .none, size: 40) {
                store.icon(for: info)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName).font(.headline)
                    if let version = info.version { Text("v\(version.description)").foregroundStyle(.secondary) }
                    if info.isLibrary { Tag(text: "Library") }
                    if info.inDevelopmentFolder { Tag(text: "Dev folder") } else if info.origin == nil { Tag(text: "Local") }
                    if info.hasBackground { Tag(text: "Background") }
                }
                if let author = info.manifest?.author.name {
                    Text("by \(author)").font(.caption).foregroundStyle(.secondary)
                }
                if let description = info.manifest?.description {
                    Text(description).foregroundStyle(.secondary).lineLimit(2)
                }
                if let error = info.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else if info.isLibrary {
                    Text(info.usedBy.isEmpty ? "Not used by any enabled extension" : "Used by " + info.usedBy.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary)
                } else if let matches = info.manifest?.matches {
                    Text(matches.joined(separator: "  \u{00B7}  ")).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if !info.isLibrary {
                    Toggle("", isOn: Binding(get: { info.isEnabled }, set: setEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(info.error != nil)
                }
                if let entry = store.update(for: info.id) {
                    Button("Update to \(entry.manifest.version)") { update(entry) }.controlSize(.small)
                }
                HStack(spacing: 10) {
                    if info.origin == nil {
                        Button(action: openEditor) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                            .buttonStyle(.borderless)
                            .help("Open in \(CodeEditor.preferred?.name ?? "Finder")")
                    }
                    Button(action: openLogs) {
                        Image(systemName: unreadErrors > 0 ? "exclamationmark.triangle.fill" : "text.alignleft")
                            .foregroundStyle(unreadErrors > 0 ? Color.red : Color.primary)
                    }
                    .buttonStyle(.borderless)
                    .help(unreadErrors > 0 ? "Logs (\(unreadErrors) new error\(unreadErrors == 1 ? "" : "s"))" : "Logs")
                    if hasSettings {
                        Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                            .help("Extension settings")
                    }
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Extension settings

private struct ExtensionSettingsSheet: View {
    let info: ExtensionInfo
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var settings: ExtensionSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let schema = manager.settingsSchema(info.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ExtensionIconView(id: info.id, name: info.displayName, spec: info.manifest?.iconSpec ?? .none, size: 40) {
                    StoreModel.shared.icon(for: info)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.displayName).font(.title3.bold())
                    Text("Settings").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            if schema.isEmpty {
                Text("This extension has no settings.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(schema) { definition in
                            SettingRow(id: info.id, definition: definition, schema: schema, settings: settings)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Button("Reset All") {
                    for definition in schema { settings.reset(info.id, key: definition.key, schema: schema) }
                }
                .disabled(!schema.contains { settings.isCustomized(info.id, $0) })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 460)
    }
}

private struct SettingRow: View {
    let id: String
    let definition: SettingDefinition
    let schema: [SettingDefinition]
    @ObservedObject var settings: ExtensionSettings
    @State private var error: String?

    private var current: SettingValue { settings.value(id, definition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(definition.title).font(.headline)
                Spacer()
                if settings.isCustomized(id, definition) {
                    Button("Reset") {
                        settings.reset(id, key: definition.key, schema: schema)
                        error = nil
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
            control
            if let description = definition.description {
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.type {
        case .boolean:
            Toggle("", isOn: Binding(
                get: { if case .bool(let flag) = current { return flag } else { return false } },
                set: { commit(.bool($0)) }))
                .labelsHidden().toggleStyle(.switch)
        case .choice:
            Picker("", selection: Binding(
                get: { if case .string(let text) = current { return text } else { return "" } },
                set: { commit(.string($0)) })) {
                ForEach(definition.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden().frame(maxWidth: 260, alignment: .leading)
        case .number:
            HStack {
                TextField("", value: Binding(
                    get: { if case .number(let number) = current { return number } else { return 0 } },
                    set: { commit(.number($0)) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                if definition.min != nil || definition.max != nil {
                    Text(rangeHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .string:
            CommitTextField(placeholder: definition.placeholder ?? "", value: { if case .string(let text) = current { return text } else { return "" } }()) {
                commit(.string($0))
            }
        }
    }

    private var rangeHint: String {
        func text(_ number: Double) -> String { number == number.rounded() ? String(Int(number)) : String(number) }
        switch (definition.min, definition.max) {
        case let (min?, max?): return "\(text(min)) to \(text(max))"
        case let (min?, nil): return "at least \(text(min))"
        case let (nil, max?): return "at most \(text(max))"
        default: return ""
        }
    }

    private func commit(_ value: SettingValue) {
        do {
            try settings.set(id, key: definition.key, value: value, schema: schema)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Saves when the user presses Return or leaves the field, not on every keystroke.
private struct CommitTextField: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(placeholder: String, value: String, commit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.value = value
        self.commit = commit
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(text) } }
            .onChange(of: value) { _, newValue in text = newValue }
    }
}

// MARK: - Developing extensions

struct NewExtensionSheet: View {
    let manager: ExtensionManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false
    @State private var summary = ""
    @State private var template = ExtensionTemplate.page
    @State private var pages = ""
    @State private var location = AppPaths.extensions.standardizedFileURL.path
    @State private var openInEditor = true
    @State private var error: String?

    private var folders: [URL] { [AppPaths.extensions] + DevelopmentFolders.urls }
    private var currentPage: URL? { SettingsWindowController.shared.currentPageURL?() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name, prompt: Text("Case Helper"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, new in if !idEdited { id = ExtensionScaffold.slug(new) } }
                }
                LabeledContent("Id") {
                    TextField("", text: Binding(get: { id }, set: { id = $0; idEdited = true }), prompt: Text("case-helper"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("What it does") {
                    TextField("", text: $summary, prompt: Text("One sentence"))
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Template", selection: $template) {
                    ForEach(ExtensionTemplate.allCases) { Text($0.title).tag($0) }
                }
                Text(template.detail).font(.caption).foregroundStyle(.secondary)

                if template.needsPages {
                    LabeledContent("Pages") {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("", text: $pages, prompt: Text(verbatim: "*://example.com/*"))
                                .textFieldStyle(.roundedBorder)
                            Button("Use Current Page") { pages = currentPage.flatMap(ExtensionScaffold.pattern(for:)) ?? pages }
                                .disabled(currentPage.flatMap(ExtensionScaffold.pattern(for:)) == nil)
                        }
                    }
                }

                HStack {
                    Picker("Create in", selection: $location) {
                        ForEach(folders, id: \.standardizedFileURL.path) { folder in
                            Text(folder == AppPaths.extensions ? "Satellite\u{2019}s extensions folder" : folder.path)
                                .tag(folder.standardizedFileURL.path)
                        }
                    }
                    Button("Choose Folder\u{2026}") { chooseFolder() }
                }
                Toggle("Open in \(CodeEditor.preferred?.name ?? "Finder") afterwards", isOn: $openInEditor)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || id.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560)
        .onAppear {
            if let url = currentPage, let pattern = ExtensionScaffold.pattern(for: url) { pages = pattern }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Extensions are created as sub-folders of this folder, and Satellite will load the ones in it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DevelopmentFolders.add(url)
        location = url.standardizedFileURL.path
    }

    private func create() {
        let parent = URL(fileURLWithPath: location, isDirectory: true)
        do {
            let folder = try ExtensionScaffold.create(
                NewExtension(name: name, id: id, summary: summary, template: template, pages: pages), in: parent)
            manager.reload()
            if openInEditor { CodeEditor.open(folder) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DevelopmentFoldersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folders = DevelopmentFolders.urls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Development folders").font(.title3.bold())
            Text("Satellite loads extensions from these folders as well as its own. Each extension is a sub-folder with a manifest.json, so you can keep them inside your own projects. Saving a file in one reloads it.")
                .font(.callout).foregroundStyle(.secondary)
            if folders.isEmpty {
                Text("None added yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(folders, id: \.path) { folder in
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show in Finder")
                        Button(role: .destructive) { DevelopmentFolders.remove(folder); folders = DevelopmentFolders.urls } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop loading extensions from this folder")
                    }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Button("Add Folder\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { DevelopmentFolders.add(url); folders = DevelopmentFolders.urls }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ExtensionLogSheet: View {
    let info: ExtensionInfo
    @ObservedObject var log: ExtensionLog
    @Environment(\.dismiss) private var dismiss

    private var entries: [ExtensionLog.Entry] { log.entries[info.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(info.displayName) logs").font(.title3.bold())
                Spacer()
                Text("\(entries.count) line\(entries.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing logged yet").font(.headline)
                    Text("console.log output and errors from this extension show up here while its pages are open.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(entry.level.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(color(entry.level))
                                .frame(width: 44, alignment: .leading)
                            Text(entry.message).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Text(entry.source).font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .id(entry.id)
                    }
                    .onChange(of: entries.count) { _, _ in if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text(for: info.id), forType: .string)
                }
                .disabled(entries.isEmpty)
                Button("Clear") { log.clear(info.id) }.disabled(entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 680, height: 460)
        .onAppear { log.markRead(info.id) }
        .onChange(of: entries.count) { _, _ in log.markRead(info.id) }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .secondary
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var confirmClear = false
    @ObservedObject var certificates = RememberedCertificates.shared
    @AppStorage(UpdateDefaults.autoCheck) private var autoCheck = true
    @ObservedObject var securityKeys = FIDODeviceMonitor.shared
    @AppStorage(SnapshotDefaults.textMode) private var snapshotText = SnapshotTextMode.labels.rawValue
    @AppStorage(SnapshotDefaults.includeGuide) private var snapshotGuide = true
    @AppStorage(CodeEditor.defaultsKey) private var editorChoice = ""

    private var versionText: String {
        let build = Bundle.main.infoDictionary?["SatelliteBuild"] as? String
        return "Satellite \(AppInfo.version)" + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        Form {
            LabeledContent(versionText) {
                Button("Check for Updates\u{2026}") { UpdateChecker.shared.check(silent: false) }
            }
            Toggle("Check for updates automatically", isOn: $autoCheck)

            Divider()

            LabeledContent("Apps & assistants") {
                Button("Reveal config.json") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config])
                }
            }
            Text("Edit config.json to change URLs, add apps, or point the store at a different repository (\u{201C}store\u{201D}), then relaunch Satellite.")
                .font(.footnote).foregroundStyle(.secondary)

            Divider()

            LabeledContent("Website data") {
                Button("Clear\u{2026}", role: .destructive) { confirmClear = true }
            }
            Text("Removes cookies and site storage, which signs you out everywhere.")
                .font(.footnote).foregroundStyle(.secondary)

            Divider()

            if CodeEditor.installed.isEmpty {
                LabeledContent("Code editor") { Text("None found; folders open in Finder").foregroundStyle(.secondary) }
            } else {
                Picker("Open extensions in", selection: $editorChoice) {
                    Text("Automatic (\(CodeEditor.installed.first?.name ?? ""))").tag("")
                    ForEach(CodeEditor.installed) { Text($0.name).tag($0.bundleID) }
                }
            }

            Divider()

            Picker("Page text in snapshots", selection: $snapshotText) {
                Text("Interface labels only").tag(SnapshotTextMode.labels.rawValue)
                Text("All text").tag(SnapshotTextMode.full.rawValue)
                Text("No text, structure only").tag(SnapshotTextMode.none.rawValue)
            }
            Toggle("Include the extension-writing guide", isOn: $snapshotGuide)
            Text("View > Copy Page for AI puts the current page (its HTML including shadow DOM and frames, clickable elements and selectors) on the clipboard. Pages often hold customer data, so by default only interface labels are kept and tokens in links are hidden. Check the result before sharing it.")
                .font(.footnote).foregroundStyle(.secondary)

            Divider()

            LabeledContent("Security keys") {
                Text(securityKeys.devices.isEmpty ? "None detected" : securityKeys.devices.map(\.name).joined(separator: ", "))
                    .foregroundStyle(securityKeys.devices.isEmpty ? .secondary : .primary)
            }
            Text("Sites that ask for a security key (such as a YubiKey) can use any USB key plugged in. Touch ID and iCloud passkeys aren\u{2019}t available in Satellite.")
                .font(.footnote).foregroundStyle(.secondary)

            Divider()

            LabeledContent("Client certificates") {
                Button("Forget All", role: .destructive) { ClientCertificateHandler.shared.forgetAll() }
                    .disabled(certificates.entries.isEmpty)
            }
            if certificates.entries.isEmpty {
                Text("Satellite picks a certificate for you when only one fits, and asks (once) when several do. Choices it remembers show up here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(certificates.entries) { entry in
                    LabeledContent(entry.scope) {
                        HStack {
                            Text(entry.name).foregroundStyle(.secondary)
                            Button("Forget") { ClientCertificateHandler.shared.forget(scope: entry.scope) }
                        }
                    }
                }
                Text("A choice covers every address under the domain. Forgetting it makes Satellite ask again. Satellite only asks when it has to: it uses the one valid certificate the server accepts and, on Salesforce sites, the one the server lists first. If none of yours fits a server, it sends none, like other browsers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all website data?", isPresented: $confirmClear) {
            Button("Clear and Sign Out Everywhere", role: .destructive) {
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast, completionHandler: {})
            }
        }
    }
}
