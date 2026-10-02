import Foundation

/// The small part of CBOR (RFC 8949) that FIDO2 uses: integers, byte and text strings, arrays, maps,
/// booleans and null. Maps are written in CTAP2 canonical order (shortest key first, then bytewise).
enum CBOR {
    case unsigned(UInt64)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid CBOR: \(reason)" }
    }

    static func int(_ value: Int) -> CBOR { value >= 0 ? .unsigned(UInt64(value)) : .negative(Int64(value)) }

    // MARK: Reading values

    var intValue: Int? {
        switch self {
        case .unsigned(let v): return v <= UInt64(Int.max) ? Int(v) : nil
        case .negative(let v): return Int(exactly: v)
        default: return nil
        }
    }
    var dataValue: Data? { if case .bytes(let d) = self { return d } else { return nil } }
    var textValue: String? { if case .text(let s) = self { return s } else { return nil } }
    var arrayValue: [CBOR]? { if case .array(let a) = self { return a } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var mapValue: [(CBOR, CBOR)]? { if case .map(let m) = self { return m } else { return nil } }

    subscript(key: Int) -> CBOR? { mapValue?.first { $0.0.intValue == key }?.1 }
    subscript(key: String) -> CBOR? { mapValue?.first { $0.0.textValue == key }?.1 }

    // MARK: Encoding

    func encoded() -> Data {
        var out = Data()
        switch self {
        case .unsigned(let value):
            Self.writeHead(0, value, to: &out)
        case .negative(let value):
            Self.writeHead(1, UInt64(-1 - value), to: &out)
        case .bytes(let data):
            Self.writeHead(2, UInt64(data.count), to: &out)
            out.append(data)
        case .text(let text):
            let data = Data(text.utf8)
            Self.writeHead(3, UInt64(data.count), to: &out)
            out.append(data)
        case .array(let items):
            Self.writeHead(4, UInt64(items.count), to: &out)
            for item in items { out.append(item.encoded()) }
        case .map(let pairs):
            let encodedPairs = pairs.map { ($0.0.encoded(), $0.1.encoded()) }
            let sorted = encodedPairs.sorted { a, b in
                a.0.count != b.0.count ? a.0.count < b.0.count : a.0.lexicographicallyPrecedes(b.0)
            }
            Self.writeHead(5, UInt64(sorted.count), to: &out)
            for (key, value) in sorted {
                out.append(key)
                out.append(value)
            }
        case .bool(let flag):
            out.append(flag ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        }
        return out
    }

    private static func writeHead(_ major: UInt8, _ value: UInt64, to out: inout Data) {
        let m = major << 5
        switch value {
        case 0..<24: out.append(m | UInt8(value))
        case 24..<0x100: out.append(contentsOf: [m | 24, UInt8(value)])
        case 0x100..<0x1_0000: out.append(contentsOf: [m | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
        case 0x1_0000..<0x1_0000_0000:
            out.append(m | 26)
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        default:
            out.append(m | 27)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        }
    }

    // MARK: Decoding

    /// Decodes exactly one item; trailing bytes are an error.
    static func decode(_ data: Data) throws -> CBOR {
        let (value, used) = try decodePrefix(data)
        guard used == data.count else { throw Failure(reason: "unexpected trailing bytes") }
        return value
    }

    /// Decodes the first item and reports how many bytes it occupied (authenticator data embeds CBOR
    /// followed by other bytes).
    static func decodePrefix(_ data: Data) throws -> (CBOR, Int) {
        let bytes = [UInt8](data)
        var index = 0
        let value = try read(bytes, &index, depth: 0)
        return (value, index)
    }

    private static func read(_ b: [UInt8], _ i: inout Int, depth: Int) throws -> CBOR {
        guard depth < 16 else { throw Failure(reason: "nested too deeply") }
        guard i < b.count else { throw Failure(reason: "truncated") }
        let initial = b[i]
        i += 1
        let major = initial >> 5
        let info = initial & 0x1F

        func argument() throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24, 25, 26, 27:
                let width = 1 << Int(info - 24)
                guard i + width <= b.count else { throw Failure(reason: "truncated") }
                var value: UInt64 = 0
                for k in 0..<width { value = (value << 8) | UInt64(b[i + k]) }
                i += width
                return value
            default: throw Failure(reason: "indefinite lengths are not allowed")
            }
        }
        func length() throws -> Int {
            let n = try argument()
            guard n <= UInt64(b.count - i) || major == 4 || major == 5 else { throw Failure(reason: "length exceeds data") }
            guard n <= 1 << 24 else { throw Failure(reason: "too large") }
            return Int(n)
        }

        switch major {
        case 0:
            return .unsigned(try argument())
        case 1:
            let n = try argument()
            guard n <= UInt64(Int64.max) else { throw Failure(reason: "integer out of range") }
            return .negative(-1 - Int64(n))
        case 2:
            let n = try length()
            guard i + n <= b.count else { throw Failure(reason: "truncated") }
            defer { i += n }
            return .bytes(Data(b[i..<i + n]))
        case 3:
            let n = try length()
            guard i + n <= b.count else { throw Failure(reason: "truncated") }
            defer { i += n }
            guard let text = String(bytes: b[i..<i + n], encoding: .utf8) else { throw Failure(reason: "invalid UTF-8") }
            return .text(text)
        case 4:
            let n = try length()
            guard n <= b.count - i else { throw Failure(reason: "array longer than data") }
            return .array(try (0..<n).map { _ in try read(b, &i, depth: depth + 1) })
        case 5:
            let n = try length()
            guard n <= b.count - i else { throw Failure(reason: "map longer than data") }
            var pairs: [(CBOR, CBOR)] = []
            for _ in 0..<n { pairs.append((try read(b, &i, depth: depth + 1), try read(b, &i, depth: depth + 1))) }
            return .map(pairs)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            default: throw Failure(reason: "unsupported simple value")
            }
        default:
            throw Failure(reason: "unsupported item type")
        }
    }
}
