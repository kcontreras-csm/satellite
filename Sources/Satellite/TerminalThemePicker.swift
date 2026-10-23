import SwiftUI

/// The theme list a terminal shows from its right-click menu (or View > Terminal Theme...): search, dark or light,
/// and a swatch of each theme's colors. Picking one shows it in the terminal at once; closing keeps what is shown.
struct TerminalThemePicker: View {
    /// The theme the terminal had when the list opened; nil for System.
    let original: String?
    let preview: (TerminalTheme?) -> Void
    let done: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light"
        var id: String { rawValue }
    }

    private static let system = "\u{0}system"   // List tag for System; no Gogh name starts with NUL

    @State private var query = ""
    @State private var kind = Kind.all
    @State private var selection: String?
    @FocusState private var searching: Bool

    private var themes: [TerminalTheme] {
        let terms = query.lowercased().split(separator: " ")
        return TerminalTheme.all.filter { theme in
            (kind == .all || (kind == .dark) == theme.isDark) && terms.allSatisfy { theme.name.lowercased().contains($0) }
        }
    }

    var body: some View {
        let shown = themes
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search \(TerminalTheme.all.count) themes", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }

            ScrollViewReader { scroller in
                List(selection: $selection) {
                    if query.isEmpty && kind == .all {
                        systemRow.tag(Self.system).id(Self.system)
                    }
                    ForEach(shown) { theme in
                        ThemeRow(theme: theme).tag(theme.name).id(theme.name)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if shown.isEmpty && !(query.isEmpty && kind == .all) {
                        Text("No theme matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
                    }
                }
                .onAppear { scroller.scrollTo(original ?? Self.system, anchor: .center) }
            }

            HStack {
                Text("Themes from Gogh").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { selection = original ?? Self.system }
                    .disabled(selection == (original ?? Self.system))
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 380, height: 460)
        .onAppear {
            selection = original ?? Self.system
            searching = true
        }
        .onChange(of: selection) { _, name in
            guard let name else { return }
            preview(name == Self.system ? nil : TerminalTheme.named(name))
        }
    }

    private var systemRow: some View {
        HStack(spacing: 10) {
            ThemeSwatch(theme: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text("System")
                Text("Follows light and dark mode").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One theme: its background with "Aa" in its foreground, its name, and its eight normal ANSI colors.
private struct ThemeRow: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 10) {
            ThemeSwatch(theme: theme)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.name).lineLimit(1)
                    Tag(text: theme.isDark ? "Dark" : "Light")
                }
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.ansi[index].nsColor)).frame(width: 11, height: 7)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name), \(theme.isDark ? "dark" : "light")")
    }
}

/// A theme at a glance: its background with "Aa" in its text color. Nil is System, in the current light or dark mode.
struct ThemeSwatch: View {
    let theme: TerminalTheme?

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: theme?.background.nsColor ?? .textBackgroundColor))
            .overlay(Text("Aa").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme?.foreground.nsColor ?? .textColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            .frame(width: 34, height: 22)
            .accessibilityHidden(true)
    }
}
