import SwiftUI

/// Opens the GitHub install sheet, optionally with an address already filled in (checking for an update).
struct GitHubInstallRequest: Identifiable {
    let id = UUID()
    var address: String?
}

/// Installs an extension that isn't in the store, from a GitHub address: look it up (pinned to a commit), pick one
/// if the address holds a collection, review what it may do, acknowledge that nobody vetted it, then install.
struct GitHubInstallSheet: View {
    @ObservedObject var store: StoreModel
    @ObservedObject var manager: ExtensionManager
    var initialAddress: String?
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case lookingUp
        case failed(String)
        case found(GitHubLookup.Result)
    }

    @State private var address = ""
    @State private var phase = Phase.idle
    @State private var selectedID: String?
    @State private var acknowledged = false
    @State private var installing = false
    @State private var installError: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install from GitHub").font(.title2.bold())
                HStack {
                    TextField("https://github.com/owner/repository/tree/main/my-extension", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .focused($addressFocused)
                        .onSubmit { Task { await lookUp() } }
                    Button("Look Up") { Task { await lookUp() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }
                Text("A repository, a folder in one, or a file in that folder. You can also type owner/repository, or owner/repository/folder@branch. Public github.com repositories only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(14)
        }
        .frame(width: 560, height: 680)
        .task {
            // Libraries an extension needs may come from the store; load its list alongside the lookup.
            Task { await store.refresh() }
            if let initialAddress, !initialAddress.isEmpty {
                address = initialAddress
                await lookUp()
            } else {
                addressFocused = true
            }
        }
    }

    private var isLookingUp: Bool { if case .lookingUp = phase { return true } else { return false } }

    private var selected: (GitHubLookup.Result, GitHubLookup.Found)? {
        guard case .found(let result) = phase else { return nil }
        if let selectedID, let found = result.found(selectedID) { return (result, found) }
        return !result.isCollection && result.found.count == 1 ? (result, result.found[0]) : nil
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            VStack(spacing: 8) {
                Image(systemName: "shippingbox.and.arrow.backward").font(.largeTitle).foregroundStyle(.secondary)
                Text("Paste the address of an extension\u{2019}s folder, or of a repository that lists several in an extensions.json.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lookingUp:
            ProgressView("Reading \(address.trimmingCharacters(in: .whitespaces))\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).padding(20).fixedSize(horizontal: false, vertical: true)
        case .found(let result):
            if case let (result, found)? = selected {
                review(found, in: result)
            } else {
                collection(result)
            }
        }
    }

    private func collection(_ result: GitHubLookup.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(result.found.count) extension\(result.found.count == 1 ? "" : "s") in \(place(result)). Choose one to review.")
                .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 14)
            List(result.found) { found in
                let m = found.entry.manifest
                HStack(alignment: .top, spacing: 12) {
                    ExtensionIconView(id: m.id, name: m.name, spec: m.iconSpec, size: 36) { await store.icon(for: found.entry) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.name).font(.headline)
                            Text("v\(m.version)").foregroundStyle(.secondary)
                            if m.isLibrary { Tag(text: "Library") }
                        }
                        Text(m.description).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Review") { select(found.id) }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { select(found.id) }
            }
            if !result.issues.isEmpty {
                DisclosureGroup("\(result.issues.count) couldn\u{2019}t be read") {
                    ForEach(result.issues, id: \.folder) { Text("\($0.folder): \($0.message)").font(.caption).foregroundStyle(.secondary) }
                }
                .font(.footnote).padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
    }

    private func review(_ found: GitHubLookup.Found, in result: GitHubLookup.Result) -> some View {
        let plan = store.plan(for: found, in: result)
        let location = found.entry.location
        let alsoInstalls = plan.steps.filter { $0.id != found.id }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if result.isCollection {
                        Button { selectedID = nil; acknowledged = false; installError = nil } label: {
                            Label("All extensions in \(place(result))", systemImage: "chevron.left")
                        }
                        .buttonStyle(.link)
                    }

                    ExtensionReviewSections(entry: found.entry, plan: plan, store: store, manager: manager)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source").font(.headline)
                        if let location {
                            Text(sourceLine(location, requestedRef: found.requestedRef)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if let url = sourceURL(location) { Link("View this exact code on GitHub", destination: url).font(.caption) }
                        }
                        ForEach(alsoInstalls) { step in
                            Text("Also installs \(step.entry.manifest.name) \(step.entry.manifest.version): " + dependencySource(step.id, in: result))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Pinned to this commit: what you review here is exactly what is installed, even if the branch changes before you click Install.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Kept in view next to the Install button rather than scrolled out of sight.
            VStack(alignment: .leading, spacing: 6) {
                Label("Not from the Satellite store", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange)
                Text(warning(found.entry.manifest, others: alsoInstalls.count))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Toggle("I\u{2019}ve reviewed this code, or I trust where it comes from.", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                if let installError {
                    Label(installError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private func dependencySource(_ id: String, in result: GitHubLookup.Result) -> String {
        guard let location = result.installable(id)?.entry.location else { return "from the store" }
        let folder = location.path.isEmpty ? "" : "/" + location.path
        return "from \(location.repository)\(folder) @ \(location.ref.prefix(7))"
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            if case let (result, found)? = selected {
                Text(replacementNote(found)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                let plan = store.plan(for: found, in: result)
                Button(installing ? "Installing\u{2026}" : installTitle(found, plan: plan)) { Task { await install(found, in: result) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!acknowledged || !plan.canInstall || installing || store.busy[found.id] != nil)
            } else {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func installTitle(_ found: GitHubLookup.Found, plan: InstallPlan) -> String {
        let others = plan.steps.filter { $0.id != found.id }.count
        let base: String
        if let installed = manager.info(found.id), let version = installed.version {
            if installed.origin?.isFromGitHubAddress == true, installed.origin?.ref == found.commit { base = "Reinstall" }
            else if found.entry.manifest.semver > version { base = "Update" }
            else { base = "Replace" }
        } else {
            base = "Install"
        }
        return others > 0 ? "\(base) with \(others) dependenc\(others == 1 ? "y" : "ies")" : base
    }

    private func replacementNote(_ found: GitHubLookup.Found) -> String {
        guard let installed = manager.info(found.id), let version = installed.version?.description else { return "" }
        if installed.inDevelopmentFolder {
            return "\u{201C}\(found.id)\u{201D} is loaded from a development folder. The installed copy will be used and that folder\u{2019}s copy ignored."
        }
        guard let origin = installed.origin else {
            return "Replaces your local copy (\(version)). If you have changed it, copy it somewhere first."
        }
        if origin.isFromGitHubAddress {
            return origin.ref == found.commit ? "This exact commit (\(version)) is already installed."
                                              : "Replaces \(version), installed from \(origin.source) at \(origin.ref.prefix(7))."
        }
        return "Replaces \(version) from the store. The store won\u{2019}t offer it updates afterwards."
    }

    // MARK: Actions

    private func lookUp() async {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLookingUp else { return }
        phase = .lookingUp
        selectedID = nil
        acknowledged = false
        installError = nil
        do {
            phase = .found(try await GitHubLookup.lookUp(text))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func select(_ id: String) {
        selectedID = id
        acknowledged = false
        installError = nil
    }

    private func install(_ found: GitHubLookup.Found, in result: GitHubLookup.Result) async {
        guard acknowledged, !installing else { return }
        installing = true
        installError = nil
        defer { installing = false }
        do {
            try await store.installFromGitHub(found, in: result)
            dismiss()
        } catch {
            installError = error.localizedDescription
        }
    }

    // MARK: Text

    private func place(_ result: GitHubLookup.Result) -> String {
        result.path.isEmpty ? result.repository : "\(result.repository)/\(result.path)"
    }

    private func sourceLine(_ location: StoreLocation, requestedRef: String?) -> String {
        let folder = location.path.isEmpty ? "" : "/" + location.path
        let branch = requestedRef.map { $0 == location.ref ? "" : " (\($0))" } ?? " (default branch)"
        return "\(location.repository)\(folder) @ \(location.ref.prefix(12))\(branch)"
    }

    private func sourceURL(_ location: StoreLocation) -> URL? {
        let folder = location.path.isEmpty ? "" : "/" + (location.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location.path)
        return URL(string: "https://github.com/\(location.repository)/tree/\(location.ref)\(folder)")
    }

    private func warning(_ manifest: ExtensionManifest, others: Int) -> String {
        let reach: String
        if manifest.isLibrary {
            reach = "It is a library, so it runs inside the extensions that load it, with their access."
        } else if manifest.runsOnPages {
            reach = "It will run on the pages listed above and can read and change anything on them, including customer data."
        } else {
            reach = "It runs inside Satellite with the permissions listed above."
        }
        let also = others > 0 ? " The same goes for the \(others == 1 ? "library" : "libraries") it installs." : ""
        return "Nobody has reviewed this code for you. \(reach)\(also) Install only code you have read, or that comes from someone you trust, and only where your organization allows it."
    }
}
