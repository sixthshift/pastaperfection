import Testing
import Foundation
import Darwin
@testable import AmpereCore

/// Loopback tests for `SocketServer`/`SocketClient` (SPEC §3, §3.1; oracle.md
/// Phase 1: "socket loopback Swift Testing test: real unix socket in temp
/// dir, request -> response round-trip for get-state/set-limit/error case").
///
/// These bind a REAL unix socket at a short path (unix socket paths are
/// capped at ~104 bytes), so tests use `/tmp/ampere-test-<pid>-<n>.sock`
/// rather than a long temp-directory path, and always clean up the socket
/// file even on failure.
/// T023: `.serialized` — every test in this suite binds a real unix-domain
/// listen socket and drives real `accept()`/`close()` traffic through the
/// process's shared small-integer fd table. Swift Testing parallelizes
/// suites/tests by default; running two of these tests' independent
/// `SocketServer`/`SocketClient` pairs concurrently lets one test's fd get
/// closed (via an async `DispatchSource` cancel handler) and immediately
/// reassigned by `accept()`/`socket()` in the OTHER, unrelated test at the
/// exact moment the first test's own cleanup is still touching that fd
/// number — not a bug in the daemon's single-instance production path (only
/// one `SocketServer` ever runs there), but a real hazard for these tests'
/// side-by-side instances. `.serialized` keeps this suite's tests
/// sequential, which is what the ticket's regression tests actually need:
/// reliable, deterministic pass/fail on THIS suite's own trigger, not
/// incidental exposure to sibling tests' fd churn.
@Suite(.serialized) struct SocketTests {
    /// Handler used by these tests: decodes each line as a `Protocol.swift`
    /// `Request` and replies with the codec's own responses, so the tests
    /// exercise `SocketServer`/`SocketClient` together with the real
    /// request/response codec rather than raw string echoing.
    private static func makeHandler() -> (String) -> String {
        { line in
            let request: Request
            do {
                request = try ProtocolCodec.decodeRequest(from: line)
            } catch {
                // Malformed line: never crash the connection, reply ok:false.
                let response = AckResponse.failure("malformed request: \(error)")
                return (try? ProtocolCodec.encodeLine(response)) ?? #"{"ok":false,"error":"encode failure"}"#
            }

            if let unknownResponse = request.unknownCommandResponse {
                return (try? ProtocolCodec.encodeLine(unknownResponse)) ?? #"{"ok":false,"error":"encode failure"}"#
            }

            switch request {
            case .getState:
                let payload = GetStatePayload(
                    percent: 75,
                    isCharging: false,
                    externalConnected: true,
                    chargingPaused: true,
                    pauseReason: .limit,
                    adapterDisabled: false,
                    mode: "limit",
                    limit: 80,
                    temperatureC: 30.1,
                    health: HealthPayload(maxCapacity: 4382, designCapacity: 5088, cycleCount: 412),
                    calibration: nil
                )
                let response = GetStateResponse.success(payload)
                return (try? ProtocolCodec.encodeLine(response)) ?? #"{"ok":false,"error":"encode failure"}"#
            default:
                let response = AckResponse.success(EmptyPayload())
                return (try? ProtocolCodec.encodeLine(response)) ?? #"{"ok":false,"error":"encode failure"}"#
            }
        }
    }

    /// Short unix socket path (max ~104 chars): `/tmp/ampere-test-<pid>-<n>.sock`.
    private static func makeSocketPath(_ n: Int) -> String {
        "/tmp/ampere-test-\(ProcessInfo.processInfo.processIdentifier)-\(n).sock"
    }

    // MARK: - Round trip through the Protocol codec

    @Test func getStateRoundTripsThroughRealSocketAndCodec() throws {
        let path = Self.makeSocketPath(1)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let client = SocketClient()
        try client.connect(path: path)
        defer { client.close() }

        let requestLine = try ProtocolCodec.encodeLine(Request.getState)
        let responseLine = try client.request(requestLine, timeout: 5)
        let decoded = try ProtocolCodec.decode(GetStateResponse.self, from: responseLine)

        #expect(decoded.ok == true)
        #expect(decoded.data?.percent == 75)
        #expect(decoded.data?.mode == "limit")
        #expect(decoded.data?.limit == 80)
        #expect(decoded.data?.pauseReason == .limit)
    }

    // MARK: - Error path + connection stays usable

    @Test func malformedRequestGetsOkFalseAndConnectionStaysUsable() throws {
        let path = Self.makeSocketPath(2)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let client = SocketClient()
        try client.connect(path: path)
        defer { client.close() }

        // Malformed line: not valid JSON at all.
        let badResponseLine = try client.request("not-json-at-all", timeout: 5)
        let badDecoded = try ProtocolCodec.decode(AckResponse.self, from: badResponseLine)
        #expect(badDecoded.ok == false)
        #expect(badDecoded.error != nil)

        // Contrast: a valid request on the SAME connection afterwards still succeeds.
        let goodRequestLine = try ProtocolCodec.encodeLine(Request.getState)
        let goodResponseLine = try client.request(goodRequestLine, timeout: 5)
        let goodDecoded = try ProtocolCodec.decode(GetStateResponse.self, from: goodResponseLine)
        #expect(goodDecoded.ok == true)
        #expect(goodDecoded.data?.percent == 75)
    }

    @Test func unknownCommandGetsOkFalseAndConnectionStaysUsable() throws {
        let path = Self.makeSocketPath(3)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let client = SocketClient()
        try client.connect(path: path)
        defer { client.close() }

        let unknownLine = #"{"cmd":"bogus"}"#
        let unknownResponseLine = try client.request(unknownLine, timeout: 5)
        let unknownDecoded = try ProtocolCodec.decode(AckResponse.self, from: unknownResponseLine)
        #expect(unknownDecoded.ok == false)
        #expect(unknownDecoded.error?.contains("bogus") == true)

        // Same connection, valid request afterwards, still succeeds.
        let setLimitLine = try ProtocolCodec.encodeLine(Request.setLimit(value: 70))
        let ackLine = try client.request(setLimitLine, timeout: 5)
        let ackDecoded = try ProtocolCodec.decode(AckResponse.self, from: ackLine)
        #expect(ackDecoded.ok == true)
    }

    // MARK: - stop() removes the socket file

    @Test func stopRemovesSocketFile() throws {
        let path = Self.makeSocketPath(4)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path) == true)

        server.stop()
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    // MARK: - chmod applied after bind

    @Test func socketFilePermissionsMatchRequestedMode() throws {
        let path = Self.makeSocketPath(5)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let posixPermissions = attributes[.posixPermissions] as? NSNumber
        #expect(posixPermissions?.intValue == 0o660)
    }

    // MARK: - Multiple sequential requests on one connection

    @Test func multipleRequestsOnSameConnectionAllSucceed() throws {
        let path = Self.makeSocketPath(6)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let client = SocketClient()
        try client.connect(path: path)
        defer { client.close() }

        for value in [60, 70, 80] {
            let line = try ProtocolCodec.encodeLine(Request.setLimit(value: value))
            let responseLine = try client.request(line, timeout: 5)
            let decoded = try ProtocolCodec.decode(AckResponse.self, from: responseLine)
            #expect(decoded.ok == true)
        }
    }

    // MARK: - request() times out cleanly when no response would ever arrive

    @Test func requestTimesOutWhenServerNeverStarted() throws {
        let path = Self.makeSocketPath(7)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = SocketClient()
        #expect(throws: (any Error).self) {
            try client.connect(path: path)
        }
    }

    // MARK: - T023 regression: the exact live daemon-wedging trigger
    //
    // These two tests pin down the live failure that motivated T023: a
    // client that disconnects without reading its response must never take
    // down the server (via `SIGPIPE` on the subsequent write to its
    // already-closed peer) or block any other connection. Both tests operate
    // purely at the `SocketServer`/`SocketClient` layer (this suite's
    // target, `AmpereCoreTests`, has no visibility into `ampered`'s
    // `Daemon`/`DaemonServer`, where the original main-queue deadlock lived)
    // — they exercise the exact conditions (slow handler + a disconnecting
    // client; concurrent clients) that `DaemonServer` layers its
    // `stateQueue.sync` bridge on top of.

    /// Connects a raw, short-lived unix-domain client: writes `line` (+
    /// newline) then closes immediately WITHOUT reading any response. This
    /// is deliberately built on raw Darwin socket calls (not `SocketClient`,
    /// whose `request(_:timeout:)` always reads back a response) so the
    /// "disconnect before reading" trigger can be reproduced exactly.
    private static func connectSendAndCloseWithoutReading(path: String, line: String) {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count < maxLen else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<utf8.count { base[i] = utf8[i] }
            base[utf8.count] = 0
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return }

        var data = Data(line.utf8)
        data.append(0x0A)
        _ = data.withUnsafeBytes { ptr -> Int in
            write(sock, ptr.baseAddress, ptr.count)
        }
        // `defer` above closes `sock` here, WITHOUT ever reading a response —
        // this is the exact live trigger: the server's handler is still
        // running (or about to write back) against a peer that is already
        // gone.
    }

    /// THE live-failure regression (T023): with a handler that sleeps ~100ms
    /// before responding (standing in for the daemon's real, non-trivial
    /// `evaluate()`/SMC work), client A connects, sends a request, and closes
    /// without ever reading the response; client B then connects, sends its
    /// own request, and must receive a correct response well within 2 s.
    /// Before T023's `SO_NOSIGPIPE`/non-blocking-accept fixes, a write to
    /// client A's already-closed socket could raise `SIGPIPE` (default
    /// disposition: terminate the process) or otherwise wedge the server —
    /// either way client B would never get its response.
    @Test func clientThatDisconnectsWithoutReadingNeverBlocksASubsequentClient() throws {
        let path = Self.makeSocketPath(8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let handler: (String) -> String = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return #"{"ok":true}"#
        }
        let server = SocketServer(path: path, mode: 0o660, handler: handler)
        try server.start()
        defer { server.stop() }

        Self.connectSendAndCloseWithoutReading(path: path, line: #"{"cmd":"get-state"}"#)

        let clientB = SocketClient()
        try clientB.connect(path: path)
        defer { clientB.close() }

        let responseLine = try clientB.request(#"{"cmd":"get-state"}"#, timeout: 2)
        #expect(responseLine.contains(#""ok":true"#))
    }

    /// Two concurrent clients (background queues), each sending its own
    /// request over its own connection, must both receive their correct
    /// response — the per-connection serial queues in `SocketServer` must
    /// not interfere with each other.
    @Test func twoConcurrentClientsBothReceiveCorrectResponses() throws {
        let path = Self.makeSocketPath(9)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path, mode: 0o660, handler: Self.makeHandler())
        try server.start()
        defer { server.stop() }

        let resultsLock = NSLock()
        var results: [Int: Result<String, Error>] = [:]
        let group = DispatchGroup()

        for value in [61, 62] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let client = SocketClient()
                    try client.connect(path: path)
                    defer { client.close() }
                    let line = try ProtocolCodec.encodeLine(Request.setLimit(value: value))
                    let response = try client.request(line, timeout: 5)
                    resultsLock.lock()
                    results[value] = .success(response)
                    resultsLock.unlock()
                } catch {
                    resultsLock.lock()
                    results[value] = .failure(error)
                    resultsLock.unlock()
                }
            }
        }

        let waitOutcome = group.wait(timeout: .now() + 5)
        #expect(waitOutcome == .success)

        for value in [61, 62] {
            let outcome = try #require(results[value])
            let response = try outcome.get()
            let decoded = try ProtocolCodec.decode(AckResponse.self, from: response)
            #expect(decoded.ok == true)
        }
    }

    // MARK: - T026 regression: large responses must not be truncated by
    // inherited O_NONBLOCK on accepted fds
    //
    // The listen fd is deliberately `O_NONBLOCK` (see `SocketServer.start()`,
    // needed so `acceptPending()`'s drain loop can terminate on
    // EAGAIN/EWOULDBLOCK instead of blocking forever). On macOS/BSD, a socket
    // returned by `accept()` INHERITS that flag from the listen fd — it is
    // not reset to blocking automatically. `Connection.writeAll` only
    // retries on `EINTR`; on a non-blocking fd, once a response outgrows the
    // unix-domain socket's small kernel send buffer (a few KB), `write()`
    // returns -1/EAGAIN and `writeAll` treats that as a fatal error, closing
    // the connection mid-response. Small responses never fill that buffer,
    // so this went unnoticed until a real handler (`get-stats`, ~60KB)
    // tripped it in production. This test's handler returns a single
    // response line far larger than any unix-socket buffer (250,000 chars)
    // ending in a distinctive marker character right before the newline, so
    // truncation is unambiguous: the client must receive the exact length
    // AND the trailing marker.
    @Test func largeResponseLineIsDeliveredIntactNotTruncated() throws {
        let path = Self.makeSocketPath(10)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let markerChar: Character = "Z"
        let bodyLength = 250_000
        let largeBody = String(repeating: "x", count: bodyLength - 1) + String(markerChar)
        #expect(largeBody.count == bodyLength)
        #expect(largeBody.last == markerChar)

        let handler: (String) -> String = { _ in largeBody }
        let server = SocketServer(path: path, mode: 0o660, handler: handler)
        try server.start()
        defer { server.stop() }

        let client = SocketClient()
        try client.connect(path: path)
        defer { client.close() }

        let responseLine = try client.request(#"{"cmd":"get-stats"}"#, timeout: 5)

        #expect(responseLine.count == bodyLength)
        #expect(responseLine.last == markerChar)
    }
}
