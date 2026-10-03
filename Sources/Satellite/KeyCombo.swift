import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: one key plus modifiers. Its text form ("Cmd+Shift+K") is what extensions write and what is saved.
struct KeyCombo: Hashable {
    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A single lowercase character ("k", "=", "[") or a key name ("Left", "Space", "F5").
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Keys

    private struct NamedKey {
        let name: String
        /// What NSMenuItem.keyEquivalent and NSEvent.charactersIgnoringModifiers use for the key.
        let equivalent: String
        let glyph: String
    }

    private static let named: [NamedKey] = {
        func function(_ offset: UInt32) -> String { String(UnicodeScalar(0xF700 + offset)!) }
        var keys = [
            NamedKey(name: "Space", equivalent: " ", glyph: "Space"),
            NamedKey(name: "Tab", equivalent: "\t", glyph: "\u{21E5}"),
            NamedKey(name: "Return", equivalent: "\r", glyph: "\u{21A9}"),
            NamedKey(name: "Escape", equivalent: "\u{1B}", glyph: "\u{238B}"),
            NamedKey(name: "Delete", equivalent: "\u{8}", glyph: "\u{232B}"),
            NamedKey(name: "Up", equivalent: function(0), glyph: "\u{2191}"),
            NamedKey(name: "Down", equivalent: function(1), glyph: "\u{2193}"),
            NamedKey(name: "Left", equivalent: function(2), glyph: "\u{2190}"),
            NamedKey(name: "Right", equivalent: function(3), glyph: "\u{2192}"),
        ]
        for number in 1...12 { keys.append(NamedKey(name: "F\(number)", equivalent: function(UInt32(3 + number)), glyph: "F\(number)")) }
        return keys
    }()

    private static let aliases = ["enter": "Return", "esc": "Escape", "backspace": "Delete", "del": "Delete"]

    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "alt": .option, "option": .option, "opt": .option, "shift": .shift,
    ]

    private static func isPlainKey(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol
    }

    // MARK: Creating

    /// Accepts a lowercase character or a key name, in any case. Shortcuts need Command or Control so they
    /// never swallow ordinary typing in a web page.
    init(key rawKey: String, modifiers: NSEvent.ModifierFlags) throws {
        let flags = modifiers.intersection(Self.relevant)
        guard flags.contains(.command) || flags.contains(.control) else {
            throw Problem("A shortcut needs \u{2318} (Cmd) or \u{2303} (Ctrl), so it doesn\u{2019}t get in the way of typing.")
        }
        let lowered = rawKey.lowercased()
        if Self.isPlainKey(rawKey) {
            key = lowered
        } else if let match = Self.named.first(where: { $0.name.lowercased() == (Self.aliases[lowered] ?? rawKey).lowercased() }) {
            key = match.name
        } else {
            throw Problem("\u{201C}\(rawKey)\u{201D} is not a key that can be used in a shortcut.")
        }
        self.modifiers = flags
    }

    /// Reads "Cmd+Shift+K", "ctrl+alt+left", "Cmd++" and the like.
    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var flags: NSEvent.ModifierFlags = []
        var rest = Substring(trimmed)
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex,
              let flag = Self.modifierNames[rest[..<plus].trimmingCharacters(in: .whitespaces).lowercased()] {
            flags.insert(flag)
            rest = rest[rest.index(after: plus)...]
        }
        let key = rest.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw Problem("\u{201C}\(text)\u{201D} has no key. Write it like Cmd+Shift+K.") }
        try self.init(key: key, modifiers: flags)
    }

    /// The shortcut a key press makes. Keys are named by what they type without Shift (so Shift+[ is still "[" and
    /// Shift+= is still "="), which is what the shortcut is written with on any keyboard layout.
    init(event: NSEvent) throws {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            throw Problem("That key can\u{2019}t be used in a shortcut.")
        }
        let key: String
        switch scalar.value {
        case 0x19: key = "Tab"  // Shift+Tab arrives as "back tab"
        case 0x03, 0x0D: key = "Return"
        case 0x7F, 0x08: key = "Delete"
        default:
            let text = String(Character(scalar))
            if let name = Self.named.first(where: { $0.equivalent == text })?.name {
                key = name
            } else {
                key = Self.unshiftedCharacter(forKeyCode: event.keyCode) ?? text
            }
        }
        try self.init(key: key, modifiers: event.modifierFlags)
    }

    /// What the key types with no modifiers on the current layout ("[" for the key that types "{" with Shift).
    private static func unshiftedCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = unsafeBitCast(property, to: CFData.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layoutData).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return isPlainKey(text) ? text : nil
    }

    // MARK: Showing

    /// Canonical text form; `init(parsing:)` reads it back.
    var text: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.named.contains { $0.name == key } ? key : key.uppercased())
        return parts.joined(separator: "+")
    }

    /// The way macOS writes it: \u{2303}\u{2325}\u{21E7}\u{2318}K.
    var glyphs: String {
        var result = ""
        if modifiers.contains(.control) { result += "\u{2303}" }
        if modifiers.contains(.option) { result += "\u{2325}" }
        if modifiers.contains(.shift) { result += "\u{21E7}" }
        if modifiers.contains(.command) { result += "\u{2318}" }
        return result + (Self.named.first { $0.name == key }?.glyph ?? key.uppercased())
    }

    // MARK: Menus

    var menuKey: String { Self.named.first { $0.name == key }?.equivalent ?? key }
    var menuModifiers: NSEvent.ModifierFlags { modifiers }
}
