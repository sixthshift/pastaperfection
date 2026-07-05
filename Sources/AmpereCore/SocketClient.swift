import Foundation
import Darwin

/// Plain POSIX unix-domain stream socket client, the counterpart to
/// `SocketServer` (SPEC §3: `/var/run/ampere.sock`). Speaks the same
/// newline-delimited line protocol; has no dependency on the `Protocol.swift`
/// codec — callers pass/receive raw lines and decode/encode with
/// `ProtocolCodec` themselves.
public final class SocketClient {
    /// Errors from connecting or exchanging a request. Carries the raw
    /// `errno` (where applicable) for diagnostics.
    public struct ClientError: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    private var fd: Int32 = -1
    private var inbound = Data()

    public init() {}

    /// Connects to the unix socket at `path`. Throws if the socket doesn't
    /// exist or the connection is refused.
    public func connect(path: String) throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw ClientError("socket() failed: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let utf8 = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count < maxLen else {
            Darwin.close(sock)
            throw ClientError("socket path too long (\(utf8.count) >= \(maxLen)): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<utf8.count { base[i] = utf8[i] }
            base[utf8.count] = 0
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            Darwin.close(sock)
            throw ClientError("connect() failed: errno \(err)")
        }

        self.fd = sock
        self.inbound.removeAll()
    }

    /// Sends `line` (+ newline) and reads exactly one newline-delimited
    /// response line back. Handles partial reads/writes by looping until a
    /// full write completes / a full line arrives. Throws `ClientError` if
    /// no complete response line arrives within `timeout` seconds, or if the
    /// connection is closed/erroring.
    public func request(_ line: String, timeout: TimeInterval) throws -> String {
        guard fd >= 0 else {
            throw ClientError("not connected")
        }
        var data = Data(line.utf8)
        data.append(0x0A)
        try writeAll(data)
        return try readLine(timeout: timeout)
    }

    /// Closes the connection. Safe to call multiple times.
    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        inbound.removeAll()
    }

    // MARK: - I/O helpers

    private func writeAll(_ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { ptr -> Int in
                write(fd, ptr.baseAddress! + offset, ptr.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw ClientError("write() failed: errno \(errno)")
            }
            if written == 0 {
                throw ClientError("write() returned 0 bytes written")
            }
            offset += written
        }
    }

    private func readLine(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let newlineIndex = inbound.firstIndex(of: 0x0A) {
                let lineData = inbound[..<newlineIndex]
                let line = String(decoding: lineData, as: UTF8.self)
                inbound.removeSubrange(inbound.startIndex...newlineIndex)
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, waitReadable(timeout: remaining) else {
                throw ClientError("timed out waiting for response")
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, 4096)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw ClientError("read() failed: errno \(errno)")
            }
            if n == 0 {
                throw ClientError("connection closed by server")
            }
            inbound.append(contentsOf: chunk[0..<n])
        }
    }

    /// Blocks (via `poll`) until `fd` is readable or `timeout` elapses.
    /// Returns `false` on timeout, `true` once data (or EOF) is ready.
    private func waitReadable(timeout: TimeInterval) -> Bool {
        guard timeout > 0 else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var remainingMs = Int32(min(timeout, Double(Int32.max) / 1000) * 1000)
        while true {
            let result = poll(&pfd, 1, remainingMs)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno == EINTR {
                remainingMs = max(0, remainingMs)
                continue
            }
            return false
        }
    }
}
