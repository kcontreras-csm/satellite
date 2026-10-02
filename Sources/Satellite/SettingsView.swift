import AppKit
import SwiftUI
import WebKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    var onReloadPages: (() -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = SettingsView(manager: .shared, reloadPages: { [weak self] in self?.onReloadPages?() })
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
    @ObservedObject var manager: ExtensionManager
    let reloadPages: () -> Void

    var body: some View {
        TabView {
            ExtensionsSettings(manager: manager, reloadPages: reloadPages)
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 580, height: 440)
    }
}

private struct ExtensionsSettings: View {
    @ObservedObject var manager: ExtensionManager
    let reloadPages: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.extensions.isEmpty {
                VStack(spacing: 6) {
                    Text("No extensions installed").font(.headline)
                    Text("Drop a folder containing manifest.json into the extensions folder, or install the sample.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.extensions) { info in
                    ExtensionRow(info: info) { manager.setEnabled(info.id, $0) }
                }
            }

            Text("Changes apply the next time a page loads.").font(.footnote).foregroundStyle(.secondary)

            HStack {
                Button("Reveal Folder") { NSWorkspace.shared.open(manager.directory) }
                Button("Rescan") { manager.reload() }
                Button("Install Sample") { manager.installSampleExtension() }
                Spacer()
                Button("Reload Pages", action: reloadPages)
            }
        }
    }
}

private struct ExtensionRow: View {
    let info: ExtensionInfo
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { info.isEnabled }, set: setEnabled))
                .labelsHidden()
                .disabled(info.error != nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName).font(.headline)
                    if let version = info.manifest?.version { Text("v\(version)").foregroundStyle(.secondary) }
                }
                if let description = info.manifest?.description {
                    Text(description).foregroundStyle(.secondary)
                }
                if let error = info.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else if let matches = info.manifest?.matches {
                    Text(matches.joined(separator: "  \u{00B7}  "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GeneralSettings: View {
    @State private var confirmClear = false

    var body: some View {
        Form {
            LabeledContent("Apps & assistants") {
                Button("Reveal config.json") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config])
                }
            }
            Text("Edit config.json to change URLs or add apps, then relaunch Satellite.")
                .font(.footnote).foregroundStyle(.secondary)

            Divider()

            LabeledContent("Website data") {
                Button("Clear\u{2026}", role: .destructive) { confirmClear = true }
            }
            Text("Removes cookies and site storage, which signs you out everywhere.")
                .font(.footnote).foregroundStyle(.secondary)
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
