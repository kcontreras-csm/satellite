import Foundation

/// Semantic version (major.minor.patch[-prerelease]); build metadata after "+" is ignored.
struct SemVer: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Strict "x.y.z" with an optional "-pre.release" suffix.
    init?(_ string: String) {
        let core = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let halves = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              let major = SemVer.number(numbers[0]), let minor = SemVer.number(numbers[1]), let patch = SemVer.number(numbers[2])
        else { return nil }

        var pre: [String] = []
        if halves.count == 2 {
            pre = halves[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
        }
        self.init(major, minor, patch, prerelease: pre)
    }

    fileprivate static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count <= 9 else { return nil }
        if text.count > 1 && text.hasPrefix("0") { return nil }
        return Int(text)
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A version with a prerelease sorts before the same version without one.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// A dependency requirement: "*", "1.2.3", "^1.2.3", "~1.2.3", ">=1.2", or several joined by spaces (all must hold).
struct VersionRange: Hashable, CustomStringConvertible {
    private enum Op { case eq, gt, gte, lt, lte }
    private struct Comparator: Hashable {
        let op: Op
        let version: SemVer
    }

    private let comparators: [Comparator]
    let text: String

    var description: String { text }

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        text = trimmed
        if trimmed.isEmpty || trimmed == "*" {
            comparators = []
            return
        }
        var all: [Comparator] = []
        for token in trimmed.split(whereSeparator: { $0 == " " }) {
            guard let parsed = VersionRange.comparators(for: String(token)) else { return nil }
            all += parsed
        }
        comparators = all
    }

    func contains(_ version: SemVer) -> Bool {
        comparators.allSatisfy { c in
            switch c.op {
            case .eq: return version == c.version
            case .gt: return version > c.version
            case .gte: return version >= c.version
            case .lt: return version < c.version
            case .lte: return version <= c.version
            }
        }
    }

    // Versions may be partial ("1", "1.2"); missing parts count as 0 for lower bounds.
    private static func partial(_ text: String) -> (parts: [Int], version: SemVer)? {
        let core = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let pieces = core[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let n = SemVer.number(piece) else { return nil }
            parts.append(n)
        }
        let padded = parts + Array(repeating: 0, count: 3 - parts.count)
        var pre: [String] = []
        if core.count == 2 {
            guard let full = SemVer("\(padded[0]).\(padded[1]).\(padded[2])-\(core[1])") else { return nil }
            pre = full.prerelease
        }
        return (parts, SemVer(padded[0], padded[1], padded[2], prerelease: pre))
    }

    private static func comparators(for token: String) -> [Comparator]? {
        for prefix in ["^", "~", ">=", "<=", ">", "<", "="] where token.hasPrefix(prefix) {
            guard let (parts, lower) = partial(String(token.dropFirst(prefix.count))) else { return nil }
            switch prefix {
            case "^":
                let upper: SemVer
                if lower.major > 0 || parts.count == 1 { upper = SemVer(lower.major + 1, 0, 0) }
                else if lower.minor > 0 || parts.count == 2 { upper = SemVer(0, lower.minor + 1, 0) }
                else { upper = SemVer(0, 0, lower.patch + 1) }
                return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: upper)]
            case "~":
                let upper = parts.count == 1 ? SemVer(lower.major + 1, 0, 0) : SemVer(lower.major, lower.minor + 1, 0)
                return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: upper)]
            case ">=": return [Comparator(op: .gte, version: lower)]
            case "<=": return [Comparator(op: .lte, version: lower)]
            case ">": return [Comparator(op: .gt, version: lower)]
            case "<": return [Comparator(op: .lt, version: lower)]
            default: return exactComparators(parts, lower)
            }
        }
        guard let (parts, lower) = partial(token) else { return nil }
        return exactComparators(parts, lower)
    }

    // "1" or "1.2" mean "any 1.x.x" / "any 1.2.x"; a full "1.2.3" means exactly that version.
    private static func exactComparators(_ parts: [Int], _ lower: SemVer) -> [Comparator] {
        switch parts.count {
        case 1: return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: SemVer(lower.major + 1, 0, 0))]
        case 2: return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: SemVer(lower.major, lower.minor + 1, 0))]
        default: return [Comparator(op: .eq, version: lower)]
        }
    }
}

enum AppInfo {
    /// The running app's version; falls back to the package version when run without a bundle.
    static let version: SemVer = {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return text.flatMap(SemVer.init) ?? SemVer(0, 1, 0)
    }()
}
