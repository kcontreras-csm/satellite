import AppKit
import SwiftTerm

/// A terminal color theme from Gogh: background, foreground, cursor and the 16 ANSI colors.
struct TerminalTheme: Identifiable, Hashable {
    struct RGB: Hashable {
        var red: UInt8, green: UInt8, blue: UInt8

        init?(hex: Substring) {
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            red = UInt8(value >> 16 & 0xFF); green = UInt8(value >> 8 & 0xFF); blue = UInt8(value & 0xFF)
        }

        var nsColor: NSColor { NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1) }
        /// SwiftTerm takes 16-bit components; 257 maps 0...255 onto 0...65535 exactly.
        var terminalColor: SwiftTerm.Color { SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257) }
    }

    let name: String
    let isDark: Bool
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright versions.
    let ansi: [RGB]

    var id: String { name }

    /// Every bundled theme, sorted by name; read once from `GoghThemes.data`.
    static let all: [TerminalTheme] = GoghThemes.data.split(separator: "\n").compactMap(parse)
    private static let byName: [String: TerminalTheme] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    static func named(_ name: String?) -> TerminalTheme? { name.flatMap { byName[$0] } }

    /// One line of `GoghThemes.data`: name | d or l | background | foreground | cursor | 16 ANSI colors.
    static func parse(_ line: Substring) -> TerminalTheme? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 21, !fields[0].isEmpty, fields[1] == "d" || fields[1] == "l" else { return nil }
        let colors = fields[2...].compactMap(RGB.init(hex:))
        guard colors.count == 19 else { return nil }
        return TerminalTheme(name: String(fields[0]), isDark: fields[1] == "d", background: colors[0], foreground: colors[1],
                             cursor: colors[2], ansi: Array(colors[3...]))
    }
}

extension TerminalView {
    /// Shows `theme`, or with nil the system's text colors and the standard palette. Background and foreground go
    /// first: the terminal derives its 256-color palette from them.
    ///
    /// The system colors are resolved for the view's light or dark appearance now. SwiftTerm keeps only a fixed copy
    /// of a color (on macOS its terminal echoes the RGB back a moment later, replacing a dynamic color), so
    /// `SatelliteTerminalView` calls this again whenever the appearance changes.
    @MainActor func apply(_ theme: TerminalTheme?) {
        if let theme {
            nativeBackgroundColor = theme.background.nsColor
            nativeForegroundColor = theme.foreground.nsColor
            caretColor = theme.cursor.nsColor
            installColors(theme.ansi.map(\.terminalColor))
        } else {
            var colors: [NSColor] = []
            effectiveAppearance.performAsCurrentDrawingAppearance {
                colors = [NSColor.textBackgroundColor, .textColor, .controlAccentColor].map { $0.usingColorSpace(.sRGB) ?? $0 }
            }
            nativeBackgroundColor = colors[0]
            nativeForegroundColor = colors[1]
            caretColor = colors[2]
            installColors(SwiftTerm.Color.defaultInstalledColors)
        }
    }
}
