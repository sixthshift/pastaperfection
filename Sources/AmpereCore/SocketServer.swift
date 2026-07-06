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

    /// T023: entered once per accepted connection (in `acceptPending()`) and
    /// left exactly once per connection, from that connection's OWN cancel
    /// handler, once its fd is REALLY closed (see `Connection`'s doc
    /// comments) — regardless of whether that connection was closed
    /// externally by `stop()` or closed itself earlier (e.g. a write to an
    /// already-disconnected peer). `stop()` waits on this group so it can
    /// promise every connection this server ever accepted has its fd
    /// actually closed before returning, not just "cancellation requested"
    /// for whichever connections happened to still be in `connections` at
    /// that moment. Without this, a connection that self-closed moments
    /// before `stop()` ran (and had therefore already removed itself from
    /// `connections`) could still have its async cancel-handler `close()`
    /// pending when `stop()` returned — and if a *different* socket
    /// operation (e.g. a subsequent test's `SocketServer`) got that exact fd
    /// number back from the kernel in the meantime, the stale handler's
    /// later `close()` would silently close the new owner's live socket.
    private let connectionsDoneGroup = DispatchGroup()

    /// T023: signaled from the listen source's cancel handler once it has
    /// actually `close()`d the listen fd. A `DispatchSource`'s cancellation
    /// is asynchronous — calling `.cancel()` only *requests* it; the cancel
    /// handler (where the real `close()` lives, per Apple's documented
    /// pattern — closing the fd any earlier risks the source's kqueue
    /// registration racing a concurrent event) runs at some later,
    /// unspecified point on `queue`. `stop()` waits on this semaphore so it
    /// can promise callers the fd is REALLY gone before returning — without
    /// this, tests that immediately create a new `SocketServer`/socket right
    /// after `stop()` intermittently got the exact fd number back from the
    /// kernel while this fd's own cancel handler was still pending,
    /// so the stale handler's later `close()` call closed the NEW owner's
    /// live socket out from under it (the exact intermittent failure this
    /// fix was written against).
    private let listenCancelledSemaphore = DispatchSemaphore(value: 0)

    public init(path: String, mode: mode_t, handler: @escaping (String) -> String) {
        self.path = path
        self.mode = mode
        self.handler = handler
    }

    /// Creates, binds, chmods, and starts listening on the unix socket at
    /// `path`. Any stale socket file at `path` is unlinked first (e.g. from a
    /// prior crashed run). Returns once the socket is accepting connections.
    public func start() throws {
        // T023: process-wide SIGPIPE guard, installed here rather than only
        // relying on the daemon's own startup path (`main.swift`/
        // `Daemon.run()`) — `SocketServer` documents itself as having "NO
        // dependency on daemon internals", and this same reliance-on-caller
        // gap is exactly what let a real crash slip through: `SO_NOSIGPIPE`
        // (set per accepted fd in `acceptPending()`) is belt and suspenders,
        // NOT sufficient on its own — `setsockopt(SO_NOSIGPIPE)` itself can
        // fail with EINVAL on a connection whose peer already fully
        // disconnected before this process ever called `accept()` on it
        // (confirmed via direct reproduction), which is exactly the "client
        // disconnects without reading" scenario this ticket is about. A
        // process-wide `SIG_IGN` has no such gap: every `write()` to a
        // broken pipe anywhere in this process simply returns -1/EPIPE,
        // regardless of whether the per-socket option ever took.
        signal(SIGPIPE, SIG_IGN)

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

        // T023: the listen fd must be non-blocking so `acceptPending()` can
        // drain every pending connection and return as soon as `accept()`
        // reports EAGAIN/EWOULDBLOCK, instead of parking the server queue
        // inside a blocking `accept()` call forever once the backlog is
        // empty (this previously wedged the queue if `accept()` raced the
        // listen source's readiness in a way that left no pending
        // connection, or more generally made the accept loop's termination
        // depend on `accept()` itself blocking rather than returning).
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { [listenCancelledSemaphore] in
            close(fd)
            listenCancelledSemaphore.signal()
        }
        source.resume()
        listenSource = source
    }

    /// Drains all pending connections on the listen socket (there may be more
    /// than one ready between dispatch-source wakeups). The listen fd is
    /// `O_NONBLOCK` (set in `start()`), so once the backlog is empty
    /// `accept()` returns -1/EAGAIN (or EWOULDBLOCK) immediately instead of
    /// blocking — that return is exactly the loop's exit condition. Without
    /// `O_NONBLOCK` this loop's final `accept()` call blocks the server
    /// queue forever whenever it runs with no connection actually pending,
    /// wedging every future accept and request.
    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    return
                }
                // Any other accept() error (e.g. EINTR, ECONNABORTED):
                // nothing pending we can usefully act on right now — try
                // again on the next listen-source wakeup rather than
                // spinning.
                return
            }

            // T023: SIGPIPE must never kill or wedge the daemon — a write to
            // a peer that has already closed its end raises SIGPIPE by
            // default. `SIG_IGN` is installed process-wide by the daemon at
            // startup (see `main.swift`), and `SO_NOSIGPIPE` here is belt and
            // suspenders for any context (e.g. this library's own tests)
            // that doesn't install the process-wide handler.
            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            // Accepted fds are intentionally left blocking: reads are driven
            // by `DispatchSourceRead`, which only fires when data is
            // actually available, so a blocking `read()` there never stalls.
            // `writeAll` below can still block on a peer that stops draining
            // its receive buffer — that only parks this one connection's own
            // serial queue, never the shared accept/listen queue, which is
            // an acceptable, documented trade-off (see `writeAll`).
            connectionsDoneGroup.enter()
            let connection = Connection(fd: clientFD, handler: handler) { [weak self] connection in
                // T023: fired from the connection's cancel handler AFTER its
                // fd is actually closed (not at cancel-request time) — see
                // `connectionsDoneGroup`'s doc comment.
                self?.remove(connection)
                self?.connectionsDoneGroup.leave()
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
    /// listen socket, and removes the socket file at `path`. Blocks until
    /// every fd this server ever opened (listen + every accepted
    /// connection, including ones that already closed themselves) is
    /// actually closed — see `connectionsDoneGroup`/`listenCancelledSemaphore`.
    ///
    /// T023: `stop()` is called from whatever thread the caller is on — not
    /// necessarily `queue`, which is the queue `acceptPending()` (and
    /// `listenFD`/`listenSource`) actually live on. The listen-socket
    /// teardown below is therefore routed through `queue.sync`, mirroring
    /// `Connection.requestClose()`'s fix for the same class of bug: without
    /// this, `stop()` could mutate `listenFD`/cancel `listenSource`
    /// concurrently with an in-flight `acceptPending()` call still reading
    /// `listenFD` on `queue`, racing a plain `Int32` write against a read
    /// from another thread. Safe as `sync` (no self-deadlock risk): nothing
    /// on `queue` ever calls back into `stop()`.
    public func stop() {
        connectionsLock.lock()
        let liveConnections = connections
        connectionsLock.unlock()
        for connection in liveConnections {
            connection.requestClose()
        }
        // Block until every connection this server EVER accepted (whether
        // still `liveConnections` above or already self-closed earlier) has
        // actually closed its fd — see `connectionsDoneGroup`'s doc comment.
        connectionsDoneGroup.wait()

        let didCancelListenSource: Bool = queue.sync {
            if let source = listenSource {
                source.cancel()
                listenSource = nil
                return true
            }
            return false
        }
        // Block until the cancel handler above has actually `close()`d the
        // listen fd (see `listenCancelledSemaphore`'s doc comment) — only
        // when we just triggered a cancellation; `stop()` may be called on
        // a server whose `start()` never succeeded, or called twice, and
        // neither should hang waiting on a signal nobody will ever send.
        if didCancelListenSource {
            listenCancelledSemaphore.wait()
        }

        queue.sync {
            listenFD = -1
        }
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
            // T023: `onClose` fires HERE — after the fd is actually closed —
            // not from `closeConnection()` at cancel-request time.
            // `SocketServer.connectionsDoneGroup`'s doc comment explains why
            // that timing matters: it's what lets `stop()` wait for every
            // connection's fd to be REALLY gone, including ones that
            // self-closed (e.g. a write to an already-disconnected peer)
            // well before `stop()` ever ran.
            source.setCancelHandler { [weak self] in
                guard let self else { return }
                Darwin.close(self.fd)
                self.onClose(self)
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
        /// The fd is blocking (see `acceptPending()`), so a peer that never
        /// drains its receive buffer can block this call indefinitely — but
        /// that only blocks *this connection's* dedicated serial `queue`,
        /// never the shared listen/accept queue or any other connection, so
        /// it cannot wedge the server. `SO_NOSIGPIPE` (set in
        /// `acceptPending()`) plus the process-wide `SIG_IGN` (installed by
        /// the daemon at startup) mean a write to an already-closed peer
        /// returns -1/EPIPE here rather than raising SIGPIPE.
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

        /// Called by `SocketServer.stop()` from whatever thread the caller is
        /// on — NOT necessarily this connection's own `queue`. Hopping onto
        /// `queue` via `sync` here (rather than calling `closeConnection()`
        /// directly) is load-bearing, not just tidy: without it, `stop()`
        /// could cancel `readSource` and let its cancel handler
        /// `Darwin.close(fd)` the socket WHILE `readAvailable()` /
        /// `processCompleteLines()` is still in flight for this exact
        /// connection on `queue` (e.g. mid-`writeAll`). That's a genuine fd
        /// race — this fd number can be reassigned by `accept()` on a wholly
        /// unrelated connection the instant it's closed, so a write that
        /// began before the race but completes after it can silently write
        /// to (or `setsockopt` on) someone else's socket. Routing this
        /// through `queue.sync` serializes it after any in-flight
        /// read/handle/write on this connection, closing that race. Safe as
        /// `sync` (no self-deadlock risk): internal self-closes always call
        /// `closeConnection()` directly from code already running on
        /// `queue`, never through this method. Only *requests* cancellation
        /// — the fd isn't actually closed until the cancel handler runs
        /// (see `start()`); callers that need that guarantee (`stop()`) wait
        /// on `SocketServer.connectionsDoneGroup` instead of on this call.
        func requestClose() {
            queue.sync {
                closeConnection()
            }
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
        }
    }
}
