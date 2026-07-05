import Testing
import Foundation
@testable import AmpereCore

/// Loopback tests for `SocketServer`/`SocketClient` (SPEC §3, §3.1; oracle.md
/// Phase 1: "socket loopback Swift Testing test: real unix socket in temp
/// dir, request -> response round-trip for get-state/set-limit/error case").
///
/// These bind a REAL unix socket at a short path (unix socket paths are
/// capped at ~104 bytes), so tests use `/tmp/ampere-test-<pid>-<n>.sock`
/// rather than a long temp-directory path, and always clean up the socket
/// file even on failure.
@Suite struct SocketTests {
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
}
