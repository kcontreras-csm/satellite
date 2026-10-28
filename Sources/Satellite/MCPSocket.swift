import Darwin
import Foundation

/// The local Unix socket `MCPStdioServer` (a tiny process spawned per agent session) uses to ask the running app
/// to capture a page, and `MCPBridge` listens on. One line of JSON each way, like the line-based protocols already
/// used for the Case Assistant's subprocess.
enum MCPSocket {
    static var path: String { AppPaths.support.appendingPathComponent("mcp.sock").path }

    /// A `sockaddr_un` for `path`, or nil if it doesn't fit (it always does: this path lives under Application Support).
    static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// Writes `object` as one line of JSON. Does nothing if it can't be encoded or the write fails.
    static func sendLine(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Blocks until a full line (up to the next `\n`) arrives, or the connection ends or sends too much.
    static func receiveLine(from fd: Int32) -> [String: Any]? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(10) {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
            if buffer.count > 1_000_000 { return nil }   // a request or response here is always one short line
        }
        guard let end = buffer.firstIndex(of: 10) else { return nil }
        return try? JSONSerialization.jsonObject(with: buffer[..<end]) as? [String: Any]
    }
}
