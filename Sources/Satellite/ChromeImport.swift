import Foundation

/// Best-effort import of Chrome's open tabs, from Chrome's own session files on disk.
///
/// Chrome's AppleScript support exposes open tabs but not tab groups at all, and its "saved tab groups" are only
/// the ones a user explicitly saved/synced — most open tabs and all ad hoc groups aren't there. The only place
/// with the full current session is Chrome's own `Sessions/Tabs_*` and `Session_*` files, in SNSS: an internal,
/// undocumented, binary format with no public schema, versioned per Chrome release.
///
/// This doesn't parse that format structurally (Chrome gives no guarantee its layout stays stable, so a command
/// parser could silently misread a different version). Instead it scans the raw bytes for strings that look like
/// `http(s)://` URLs, in either encoding Chrome uses for pickled strings. That means: it can surface stale entries
/// (a tab's back/forward history, not just what's open now), it never recovers tab groups (Chrome doesn't write
/// those in a way this can distinguish from a plain tab), and a future Chrome version could change enough that
/// this finds nothing. Treat every result as a lead to review, not a fact — nothing here is opened without the
/// user choosing it first.
enum ChromeImport {
    struct FoundTab: Identifiable, Hashable {
        let id = UUID()
        let url: URL
    }

    /// Scans the most recently modified session files across every Chrome profile found. `limit` caps how many
    /// distinct URLs are returned, so a pathological file can't make the review list unusable.
    static func scanRecentSessionFiles(limit: Int = 300) -> [FoundTab] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let chromeBase = support.appendingPathComponent("Google/Chrome")
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: chromeBase, includingPropertiesForKeys: nil) else { return [] }

        var seen = Set<String>()
        var found: [URL] = []
        for profile in profiles {
            guard found.count < limit else { break }
            let sessions = profile.appendingPathComponent("Sessions")
            guard let files = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let recent = files
                .filter { $0.lastPathComponent.hasPrefix("Tabs_") || $0.lastPathComponent.hasPrefix("Session_") }
                .sorted {
                    let a = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let b = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return (a ?? .distantPast) > (b ?? .distantPast)
                }
                .prefix(6)   // a few recent files per profile; older ones are mostly redundant history
            for file in recent {
                guard found.count < limit, let data = try? Data(contentsOf: file) else { continue }
                for url in urls(in: data) where !seen.contains(url.absoluteString) {
                    seen.insert(url.absoluteString)
                    found.append(url)
                    if found.count >= limit { break }
                }
            }
        }
        return found.map(FoundTab.init)
    }

    /// Finds `http(s)://` URLs in raw bytes: plain ASCII (pickled `std::string`) or UTF-16LE (pickled
    /// `std::u16string`), since Chrome's session commands use either depending on the field and version.
    private static func urls(in data: Data) -> [URL] {
        let bytes = [UInt8](data)
        let schemes: [[UInt8]] = [Array("https://".utf8), Array("http://".utf8)]
        var results: [URL] = []
        var i = 0
        while i < bytes.count {
            if let scheme = schemes.first(where: { matches(bytes, at: i, scheme: $0, wide: false) }) {
                if let url = readURL(bytes, from: i, wide: false) { results.append(url) }
                i += scheme.count
                continue
            }
            if let scheme = schemes.first(where: { matches(bytes, at: i, scheme: $0, wide: true) }) {
                if let url = readURL(bytes, from: i, wide: true) { results.append(url) }
                i += scheme.count * 2
                continue
            }
            i += 1
        }
        return results
    }

    private static func matches(_ bytes: [UInt8], at i: Int, scheme: [UInt8], wide: Bool) -> Bool {
        let stride = wide ? 2 : 1
        guard i + scheme.count * stride <= bytes.count else { return false }
        for (k, b) in scheme.enumerated() {
            if bytes[i + k * stride] != b { return false }
            if wide, bytes[i + k * stride + 1] != 0 { return false }
        }
        return true
    }

    /// Reads a candidate URL starting at `from`, stopping at the first byte that can't be part of one (whitespace,
    /// control characters, quotes, angle brackets from the surrounding binary) or at `maxLength`.
    private static func readURL(_ bytes: [UInt8], from start: Int, wide: Bool, maxLength: Int = 2000) -> URL? {
        var chars: [UInt8] = []
        var i = start
        let stride = wide ? 2 : 1
        while i + stride <= bytes.count, chars.count < maxLength {
            let b = bytes[i]
            if wide, bytes[i + 1] != 0 { break }
            if b < 0x21 || b == 0x22 || b == 0x3C || b == 0x3E || b > 0x7E { break }
            chars.append(b)
            i += stride
        }
        guard chars.count > "https://".count, let string = String(bytes: chars, encoding: .ascii),
              let url = URL(string: string), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
