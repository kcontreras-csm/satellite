import AppKit
import SwiftUI

/// The "Groups" rail button's window: every tab group across every app, to jump to one, and an import from
/// Chrome. A fresh one is built each time it's opened (see `MainWindowController.showGroupsBrowser`), so it
/// always starts with the current groups rather than needing to be kept live.
final class GroupsBrowserWindowController: NSWindowController {
    init(clusters: [ContentViewController.ClusterEntry], onJump: @escaping (String, UUID) -> Void,
         onImport: @escaping ([ChromeImport.FoundTab]) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tab Groups"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: GroupsBrowserView(
            clusters: clusters, onJump: onJump, onImport: onImport, dismiss: { [weak window] in window?.close() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

struct GroupsBrowserView: View {
    let clusters: [ContentViewController.ClusterEntry]
    var onJump: (String, UUID) -> Void
    var onImport: ([ChromeImport.FoundTab]) -> Void
    var dismiss: () -> Void

    @State private var importing = false
    @State private var scanning = false
    @State private var scanned: [ChromeImport.FoundTab] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        Group {
            if importing { importView } else { listView }
        }
        .frame(width: 420, height: 440)
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tab Groups").font(.headline)
                Spacer()
                Button("Import from Chrome\u{2026}") { startImport() }
            }.padding([.top, .horizontal])

            if clusters.isEmpty {
                Spacer()
                Text("No tab groups are open. Right-click a tab and choose Add Tab to Group to start one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal)
                Spacer()
            } else {
                List(clusters) { entry in
                    Button { onJump(entry.appID, entry.cluster.id); dismiss() } label: {
                        HStack {
                            Circle().fill(Color(nsColor: entry.cluster.color.nsColor)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.cluster.name)
                                Text("\(entry.appName) \u{2022} \(entry.tabCount) tab\(entry.tabCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
    }

    private var importView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import from Chrome").font(.headline).padding([.top, .horizontal])
            Text("Best-effort: scanned Chrome\u{2019}s own session files for URLs that look like open tabs. This can include pages you\u{2019}ve since navigated away from, and never recovers Chrome\u{2019}s tab groups — Chrome doesn\u{2019}t expose those here. Review before importing.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)

            if scanning {
                Spacer()
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else if scanned.isEmpty {
                Spacer()
                Text("Nothing recognizable was found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(scanned) { tab in
                    Toggle(isOn: Binding(
                        get: { selected.contains(tab.id) },
                        set: { on in if on { selected.insert(tab.id) } else { selected.remove(tab.id) } })) {
                        Text(tab.url.absoluteString).lineLimit(1).truncationMode(.middle)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Back") { importing = false }
                Spacer()
                Button("Import \(selected.count) Tab\(selected.count == 1 ? "" : "s")") {
                    onImport(scanned.filter { selected.contains($0.id) })
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }.padding([.horizontal, .bottom])
        }
    }

    private func startImport() {
        importing = true
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ChromeImport.scanRecentSessionFiles()
            DispatchQueue.main.async {
                scanned = result
                selected = Set(result.map(\.id))
                scanning = false
            }
        }
    }
}
