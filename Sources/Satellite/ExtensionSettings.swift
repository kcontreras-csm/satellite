import Combine
import Foundation

// MARK: - Values

enum SettingValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let flag = try? single.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? single.decode(Double.self) {
            self = .number(number)
        } else if let text = try? single.decode(String.self) {
            self = .string(text)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "expected a string, number or boolean")
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let text): try single.encode(text)
        case .number(let number): try single.encode(number)
        case .bool(let flag): try single.encode(flag)
        }
    }

    /// A value that can be sent to JavaScript.
    var jsonObject: Any {
        switch self {
        case .string(let text): return text
        case .number(let number): return number
        case .bool(let flag): return flag
        }
    }

    /// Converts a value received from JavaScript (NSString / NSNumber).
    init?(any value: Any) {
        if let number = value as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        } else if let text = value as? String {
            self = .string(text)
        } else {
            return nil
        }
    }
}

// MARK: - Definitions

/// One user-editable option an extension exposes in Settings. Declared in manifest.json under
/// "settings", or at runtime with `satellite.settings.register(...)`.
struct SettingDefinition: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case string, number, boolean, choice
    }

    struct Option: Codable, Hashable {
        var value: String
        var label: String
    }

    var key: String
    var type: Kind
    var title: String
    var description: String?
    var defaultValue: SettingValue?
    var options: [Option]?
    var min: Double?
    var max: Double?
    var placeholder: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, type, title, description, options, min, max, placeholder
        case defaultValue = "default"
    }

    static let maxStringLength = 2000

    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, (1...40).contains(key.count) else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789_.-"))
        return letters.contains(first) && key.unicodeScalars.allSatisfy(rest.contains)
    }

    /// Checks the definition and fills in the implied default (first option for a choice).
    func validated() throws -> SettingDefinition {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ message: String) -> ManifestError { ManifestError("setting \u{201C}\(key)\u{201D}: \(message)") }

        guard Self.isValidKey(key) else {
            throw ManifestError("setting key \u{201C}\(key)\u{201D} must start with a letter and use only letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} or \u{201C}_\u{201D} (40 characters at most)")
        }
        guard !copy.title.isEmpty, copy.title.count <= 80 else { throw fail("needs a title of 1\u{2013}80 characters") }
        if let description, description.count > 300 { throw fail("description is longer than 300 characters") }
        if let min, let max, min > max { throw fail("\u{201C}min\u{201D} is greater than \u{201C}max\u{201D}") }

        switch type {
        case .choice:
            guard let options, (1...50).contains(options.count) else { throw fail("a choice needs 1\u{2013}50 options") }
            guard options.allSatisfy({ !$0.value.isEmpty && !$0.label.isEmpty }), Set(options.map(\.value)).count == options.count else {
                throw fail("options need unique, non-empty values and labels")
            }
            if copy.defaultValue == nil { copy.defaultValue = .string(options[0].value) }
        case .string, .number, .boolean:
            if options != nil { throw fail("only a choice has options") }
        }
        if let defaultValue = copy.defaultValue {
            do { _ = try copy.coerce(defaultValue) } catch { throw fail("default: \(error.localizedDescription)") }
        }
        return copy
    }

    /// Value used until the user changes it.
    var effectiveDefault: SettingValue {
        if let defaultValue { return defaultValue }
        switch type {
        case .string: return .string("")
        case .number: return .number(min ?? 0)
        case .boolean: return .bool(false)
        case .choice: return .string(options?.first?.value ?? "")
        }
    }

    /// Returns `value` if it is acceptable for this setting, otherwise throws why not.
    func coerce(_ value: SettingValue) throws -> SettingValue {
        switch (type, value) {
        case (.string, .string(let text)):
            guard text.count <= Self.maxStringLength else { throw ManifestError("must be \(Self.maxStringLength) characters or fewer") }
            return value
        case (.number, .number(let number)):
            guard number.isFinite else { throw ManifestError("must be a finite number") }
            if let min, number < min { throw ManifestError("must be at least \(Self.format(min))") }
            if let max, number > max { throw ManifestError("must be at most \(Self.format(max))") }
            return value
        case (.boolean, .bool):
            return value
        case (.choice, .string(let text)):
            guard options?.contains(where: { $0.value == text }) == true else { throw ManifestError("must be one of the listed options") }
            return value
        default:
            throw ManifestError("has the wrong type (expected \(type.rawValue))")
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}

// MARK: - Store

/// Values the user has chosen for each extension's settings, plus settings an extension registered at runtime.
/// Persisted per extension in ExtensionData/<id>.settings.json.
final class ExtensionSettings: ObservableObject {
    static let shared = ExtensionSettings()
    static let changed = Notification.Name("SatelliteExtensionSettingChanged")
    static let maxSettings = 40

    /// Bumped on every change so SwiftUI views refresh.
    @Published private(set) var revision = 0

    private struct Stored: Codable {
        var values: [String: SettingValue] = [:]
        var schema: [SettingDefinition] = []
    }

    private var cache: [String: Stored] = [:]

    // MARK: Reading

    /// Settings registered from JavaScript at runtime.
    func dynamicSchema(_ id: String) -> [SettingDefinition] { load(id).schema }

    func value(_ id: String, _ definition: SettingDefinition) -> SettingValue {
        if let stored = load(id).values[definition.key], (try? definition.coerce(stored)) != nil { return stored }
        return definition.effectiveDefault
    }

    func allValues(_ id: String, schema: [SettingDefinition]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: schema.map { ($0.key, value(id, $0).jsonObject) })
    }

    func isCustomized(_ id: String, _ definition: SettingDefinition) -> Bool {
        value(id, definition) != definition.effectiveDefault
    }

    // MARK: Writing

    func set(_ id: String, key: String, value: SettingValue, schema: [SettingDefinition]) throws {
        guard let definition = schema.first(where: { $0.key == key }) else {
            throw ManifestError("Unknown setting \u{201C}\(key)\u{201D}")
        }
        let accepted: SettingValue
        do { accepted = try definition.coerce(value) } catch { throw ManifestError("\(definition.title) \(error.localizedDescription)") }

        var stored = load(id)
        if stored.values[key] == accepted { return }
        stored.values[key] = accepted
        try save(id, stored)
        announce(id, key: key, value: accepted)
    }

    func reset(_ id: String, key: String, schema: [SettingDefinition]) {
        guard let definition = schema.first(where: { $0.key == key }) else { return }
        var stored = load(id)
        guard stored.values.removeValue(forKey: key) != nil else { return }
        try? save(id, stored)
        announce(id, key: key, value: definition.effectiveDefault)
    }

    /// Replaces the extension's runtime-registered settings. Keys declared in the manifest can't be shadowed.
    func register(_ id: String, definitions: [SettingDefinition], declared: [SettingDefinition]) throws {
        let checked = try definitions.map { try $0.validated() }
        guard declared.count + checked.count <= Self.maxSettings else {
            throw ManifestError("An extension can have at most \(Self.maxSettings) settings")
        }
        let taken = Set(declared.map(\.key))
        var seen = Set<String>()
        for definition in checked {
            guard !taken.contains(definition.key) else {
                throw ManifestError("Setting \u{201C}\(definition.key)\u{201D} is already declared in manifest.json")
            }
            guard seen.insert(definition.key).inserted else {
                throw ManifestError("Setting \u{201C}\(definition.key)\u{201D} is listed twice")
            }
        }
        var stored = load(id)
        guard stored.schema != checked else { return }
        stored.schema = checked
        try save(id, stored)
        bump()
    }

    func deleteAll(_ id: String) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
        bump()
    }

    // MARK: Persistence

    private func fileURL(_ id: String) -> URL {
        AppPaths.extensionData.appendingPathComponent("\(id).settings.json")
    }

    private func load(_ id: String) -> Stored {
        if let cached = cache[id] { return cached }
        var stored = Stored()
        if let data = try? Data(contentsOf: fileURL(id)), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
        cache[id] = stored
        return stored
    }

    private func save(_ id: String, _ stored: Stored) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL(id), options: .atomic)
        cache[id] = stored
    }

    private func bump() {
        revision += 1
    }

    private func announce(_ id: String, key: String, value: SettingValue) {
        bump()
        NotificationCenter.default.post(
            name: Self.changed, object: self, userInfo: ["id": id, "key": key, "value": value.jsonObject])
    }
}
