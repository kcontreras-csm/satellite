import AppKit
import SwiftUI

/// Settings > Shortcuts: every command of the app and of the extensions, each with the shortcut it has now.
struct ShortcutsSettings: View {
    @ObservedObject var registry = ShortcutRegistry.shared
    @ObservedObject var manager = ExtensionManager.shared

    @State private var query = ""
    @State private var recording: String?
    @State private var confirmReset = false

    private struct ShortcutSection: Identifiable {
        let title: String
        let commands: [ShortcutCommand]
        var id: String { title }
    }

    private static let groupOrder = ["Navigation", "Page", "Apps", "Assistants", "AI", "Window", "App", "Edit"]

    private func name(ofExtension id: String) -> String { manager.info(id)?.displayName ?? id }

    private var sections: [ShortcutSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = registry.commands.filter { command in
            // Standard commands without a shortcut (About, Show All...) have nothing to show here.
            if command.isFixed && registry.combo(for: command.id) == nil { return false }
            guard !needle.isEmpty else { return true }
            let owner = command.owner.map(name(ofExtension:)) ?? ""
            return [command.title, owner, registry.combo(for: command.id)?.text ?? ""].contains { $0.lowercased().contains(needle) }
        }

        var result: [ShortcutSection] = []
        for group in Self.groupOrder {
            let commands = visible.filter { $0.owner == nil && $0.group == group }
            if !commands.isEmpty { result.append(ShortcutSection(title: group, commands: commands)) }
        }
        var owners: [String] = []
        for command in visible {
            if let owner = command.owner, !owners.contains(owner) { owners.append(owner) }
        }
        for owner in owners {
            result.append(ShortcutSection(title: "Extension: \(name(ofExtension: owner))", commands: visible.filter { $0.owner == owner }))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Reset All\u{2026}") { confirmReset = true }
                    .disabled(!registry.hasCustomizations)
            }

            if sections.isEmpty {
                Text("No shortcuts match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.commands) { command in
                                ShortcutRow(command: command, registry: registry, recording: $recording)
                            }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
            }

            Text("Click a shortcut, then press the keys you want. Delete removes it and Esc cancels. A shortcut needs \u{2318} or \u{2303}, and two commands can\u{2019}t share one. Extensions add their own shortcuts here (and under the Extensions menu); they never take one that is in use.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Reset every shortcut to its default?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { registry.resetAll() }
        }
        .onDisappear { recording = nil }
    }
}

private struct ShortcutRow: View {
    let command: ShortcutCommand
    @ObservedObject var registry: ShortcutRegistry
    @Binding var recording: String?
    @State private var error: String?

    private var isRecording: Bool { recording == command.id }

    /// Why the command has no shortcut although it wants one.
    private var conflictNote: String? {
        guard registry.combo(for: command.id) == nil, let wanted = registry.wantedCombo(for: command.id),
              let holder = registry.blockingCommand(for: command.id) else { return nil }
        return "\(wanted.glyphs) is already used by \u{201C}\(holder.title)\u{201D}, so this has no shortcut yet."
    }

    var body: some View {
        let combo = registry.combo(for: command.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(command.title)
                Spacer()
                if command.isFixed {
                    Text(combo?.glyphs ?? "").foregroundStyle(.secondary)
                    Image(systemName: "lock.fill").foregroundStyle(.tertiary)
                        .help("A standard macOS shortcut. It can\u{2019}t be changed.")
                } else {
                    ShortcutRecorder(
                        owner: command.id,
                        label: isRecording ? "Type shortcut\u{2026}" : (combo?.glyphs ?? "Record Shortcut"),
                        isRecording: isRecording,
                        toggle: {
                            error = nil
                            recording = isRecording ? nil : command.id
                        },
                        handle: handle)
                    Button {
                        try? registry.setCombo(command.id, to: nil)
                        error = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(combo == nil)
                        .help("Remove the shortcut")
                    Button {
                        registry.reset(command.id)
                        error = nil
                    } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .opacity(registry.isCustomized(command.id) ? 1 : 0)
                        .disabled(!registry.isCustomized(command.id))
                        .help("Back to the default")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let conflictNote {
                Text(conflictNote).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// A key press while recording. Esc cancels, Delete removes the shortcut, anything else becomes the shortcut.
    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        if plain, event.keyCode == 53 {
            recording = nil
        } else if plain, event.keyCode == 51 || event.keyCode == 117 {
            try? registry.setCombo(command.id, to: nil)
            error = nil
            recording = nil
        } else {
            do {
                try registry.setCombo(command.id, to: try KeyCombo(event: event))
                error = nil
                recording = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The button that shows a shortcut and, once clicked, takes the next key press as the new one. While it waits it
/// sees every key first, so pressing a shortcut that already exists doesn't run it.
private struct ShortcutRecorder: View {
    let owner: String
    let label: String
    let isRecording: Bool
    let toggle: () -> Void
    let handle: (NSEvent) -> Void

    var body: some View {
        Button(action: toggle) {
            Text(label).frame(minWidth: 118)
        }
        .tint(isRecording ? .accentColor : nil)
        .onChange(of: isRecording) { _, recording in
            if recording { ShortcutRegistry.shared.captureKeys(for: owner, handle) } else { ShortcutRegistry.shared.stopCapturingKeys(for: owner) }
        }
        .onDisappear { ShortcutRegistry.shared.stopCapturingKeys(for: owner) }
    }
}
