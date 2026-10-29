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

    /// The most a request (a short command) or a response (page snapshots, several for a tab group) may be.
    static let requestLimit = 1 << 20
    static let responseLimit = 64 << 20

    /// Writing to a socket whose other end has gone (an agent that stopped waiting) raises SIGPIPE, which by
    /// default ends the whole process, with no crash report. Each MCP socket gets an error instead.
    static func ignoreBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes `object` as one line of JSON, all of it: a large write to a socket can go out in parts. Stops at
    /// the first failure (the other end closed).
    static func sendLine(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                if n > 0 { sent += n } else if n < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    /// Blocks until a full line (up to the next `\n`) arrives, or the connection ends or sends more than `limit`.
    static func receiveLine(from fd: Int32, limit: Int) -> [String: Any]? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            let start = buffer.count
            buffer.append(chunk, count: n)
            // Only the bytes just read can hold the newline; looking through all of them each time would be slow
            // for a response of several megabytes.
            if let end = buffer[start...].firstIndex(of: 10) {
                return try? JSONSerialization.jsonObject(with: buffer[..<end]) as? [String: Any]
            }
            if buffer.count > limit { return nil }
        }
    }
}
