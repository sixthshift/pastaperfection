import Foundation
import Dispatch
import Darwin

/// Plain POSIX unix-domain stream socket server (SPEC §3: `/var/run/ampere.sock`).
///
/// `SocketServer` has NO dependency on daemon internals or the `Protocol.swift`
/// codec — it accepts connections, reads newline-delimited request lines, and
/// hands each line to a plain `String -> String` handler closure, writing back
/// whatever the handler returns (+ newline). The daemon wires the `Protocol`
/// codec into that closure in a later ticket; this file only knows about raw
/// lines.
///
/// Accept + per-connection I/O run on `DispatchSourceRead`s (no blocking
/// threads to leak or hang on `stop()`), per the ticket's "DispatchSource or a
/// background thread" allowance.
public final class SocketServer {
    /// Errors from socket setup. Carries the raw `errno` for diagnostics.
    public struct ServerError: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    private let path: String
    private let mode: mode_t
    private let handler: (String) -> String

    private let queue = DispatchQueue(label: "com.ampere.socketserver")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let connectionsLock = NSLock()
    private var connections: [Connection] = []

    public init(path: String, mode: mode_t, handler: @escaping (String) -> String) {
        self.path = path
        self.mode = mode
        self.handler = handler
    }

    /// Creates, binds, chmods, and starts listening on the unix socket at
    /// `path`. Any stale socket file at `path` is unlinked first (e.g. from a
    /// prior crashed run). Returns once the socket is accepting connections.
    public func start() throws {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError("socket() failed: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let utf8 = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count < maxLen else {
            close(fd)
            throw ServerError("socket path too long (\(utf8.count) >= \(maxLen)): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<utf8.count { base[i] = utf8[i] }
            base[utf8.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw ServerError("bind() failed: errno \(err)")
        }

        guard chmod(path, mode) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ServerError("chmod() failed: errno \(err)")
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ServerError("listen() failed: errno \(err)")
        }

        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        listenSource = source
    }

    /// Drains all pending connections on the listen socket (there may be more
    /// than one ready between dispatch-source wakeups).
    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }

            let connection = Connection(fd: clientFD, handler: handler) { [weak self] connection in
                self?.remove(connection)
            }
            connectionsLock.lock()
            connections.append(connection)
            connectionsLock.unlock()
            connection.start()
        }
    }

    private func remove(_ connection: Connection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }

    /// Stops accepting new connections, closes existing ones, closes the
    /// listen socket, and removes the socket file at `path`.
    public func stop() {
        connectionsLock.lock()
        let liveConnections = connections
        connections.removeAll()
        connectionsLock.unlock()
        for connection in liveConnections {
            connection.close()
        }

        if let source = listenSource {
            source.cancel()
            listenSource = nil
        }
        listenFD = -1
        unlink(path)
    }

    // MARK: - Per-connection handling

    /// One accepted client connection: reads newline-delimited request
    /// lines, calls `handler` per line, writes the response line + newline.
    /// Handles partial reads/writes by looping until a full line/write
    /// completes.
    private final class Connection {
        private let fd: Int32
        private let handler: (String) -> String
        private let onClose: (Connection) -> Void
        private let queue = DispatchQueue(label: "com.ampere.socketserver.connection")
        private var readSource: DispatchSourceRead?
        private var inbound = Data()
        private let stateLock = NSLock()
        private var closed = false

        init(fd: Int32, handler: @escaping (String) -> String, onClose: @escaping (Connection) -> Void) {
            self.fd = fd
            self.handler = handler
            self.onClose = onClose
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailable()
            }
            source.setCancelHandler { [weak self] in
                guard let self else { return }
                Darwin.close(self.fd)
            }
            readSource = source
            source.resume()
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, 4096)
            }
            guard n > 0 else {
                // n == 0: peer closed. n < 0: read error. Either way, done.
                closeConnection()
                return
            }
            inbound.append(contentsOf: chunk[0..<n])
            processCompleteLines()
        }

        private func processCompleteLines() {
            while let newlineIndex = inbound.firstIndex(of: 0x0A) {
                let lineData = inbound[..<newlineIndex]
                let line = String(decoding: lineData, as: UTF8.self)
                inbound.removeSubrange(inbound.startIndex...newlineIndex)

                let response = handler(line)
                var responseData = Data(response.utf8)
                responseData.append(0x0A)
                if !writeAll(responseData) {
                    closeConnection()
                    return
                }
            }
        }

        /// Loops until every byte is written (handles short/partial writes).
        private func writeAll(_ data: Data) -> Bool {
            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { ptr -> Int in
                    write(fd, ptr.baseAddress! + offset, ptr.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }

        func close() {
            closeConnection()
        }

        private func closeConnection() {
            stateLock.lock()
            guard !closed else {
                stateLock.unlock()
                return
            }
            closed = true
            stateLock.unlock()

            readSource?.cancel()
            readSource = nil
            onClose(self)
        }
    }
}
