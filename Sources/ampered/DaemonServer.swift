//
// DaemonServer.swift
// ampered
//
// Wires `SocketServer` (AmpereCore) at `/var/run/ampere.sock` into live
// `Daemon` state via the `Protocol.swift` codec (SPEC §3, §3.1). This file
// owns request decoding/response encoding and the every-`cmd` switch;
// `Daemon` owns the actual state (config/ControlState/battery reading) and
// exposes small, purpose-built methods (`getStatePayload()`, `setLimit(_:)`,
// etc.) that this type calls.
//
// Thread-safety (T023): `SocketServer`'s handler runs on its own internal
// per-connection dispatch queues, potentially concurrently with the
// daemon's own timer/signal/power-notification callbacks. Every handler
// invocation is routed through `daemon.stateQueue.sync { ... }` — a plain
// serial-queue sync, with NO run loop or main-queue involvement — so all
// daemon state access is serialized on `stateQueue`, with no additional
// locking needed anywhere in `Daemon`. This is a deliberate change from an
// earlier main-queue-`sync` bridge: that version let a client which
// disconnected without reading its response wedge the main queue permanently
// (`CFRunLoopRun()` blocks that same thread/queue in `Daemon.run()`),
// silently killing the 30 s timer and the SIGTERM/SIGINT restore-charging
// path along with every other request. `stateQueue` is never blocked by the
// run loop, so a stuck handler now blocks, at worst, this one `sync` call.
//

import AmpereCore
import Darwin
import Dispatch
import Foundation

/// Socket server for the daemon's control protocol (SPEC §3.1). Thin glue:
/// decode a request line, call the matching `Daemon` method (on the main
/// queue), encode the response line.
public final class DaemonServer {
    /// SPEC §3: `/var/run/ampere.sock`, mode `0660`.
    public static let defaultSocketPath = "/var/run/ampere.sock"
    public static let defaultMode: mode_t = 0o660

    /// Fallback gid for the "staff" group (stock macOS assigns `staff` gid
    /// 20) used only if `getgrnam("staff")` can't resolve it at runtime.
    private static let fallbackStaffGID: gid_t = 20

    private let server: SocketServer
    private let path: String

    public init(daemon: Daemon, path: String = DaemonServer.defaultSocketPath) {
        self.path = path
        self.server = SocketServer(path: path, mode: DaemonServer.defaultMode) { line in
            daemon.stateQueue.sync {
                DaemonServer.handle(line, daemon: daemon)
            }
        }
    }

    /// Starts accepting connections (SPEC §3.1). Throws if the socket can't
    /// be created/bound. Once the socket file exists, fixes up its group
    /// ownership to `staff` (SPEC §3: root:staff 0660) — `bind()` otherwise
    /// leaves it owned by whatever group `/var/run` inherits (root:daemon on
    /// this machine), which locks out unprivileged (staff-group) clients
    /// with EACCES even though the file exists.
    public func start() throws {
        try server.start()
        applySocketOwnership()
    }

    /// Root-only and best-effort: the daemon runs as root in production, so
    /// this always applies there; socket loopback tests run this same code
    /// unprivileged in temp dirs, where `geteuid() != 0` makes this a no-op
    /// (chown would fail anyway) so it never perturbs those tests' sockets.
    private func applySocketOwnership() {
        guard geteuid() == 0 else { return }

        let staffGID: gid_t
        if let group = getgrnam("staff") {
            staffGID = group.pointee.gr_gid
        } else {
            staffGID = DaemonServer.fallbackStaffGID
        }

        // Best-effort: tolerate failure silently (SPEC §1 spirit — a socket
        // ownership hiccup shouldn't take down the daemon); `chmod` re-
        // asserts mode 0660 in case `chown` reset any bits.
        _ = chown(path, 0, staffGID)
        _ = chmod(path, DaemonServer.defaultMode)
    }

    /// Stops accepting connections, closes existing ones, and removes the
    /// socket file — called from the daemon's signal-restore path.
    public func stop() {
        server.stop()
    }

    // MARK: - Request handling (runs on `daemon.stateQueue`, T023)

    static func handle(_ line: String, daemon: Daemon) -> String {
        let request: Request
        do {
            request = try ProtocolCodec.decodeRequest(from: line)
        } catch {
            return encodeOrFallback(AckResponse.failure("malformed request: \(error)"))
        }

        if let unknownResponse = request.unknownCommandResponse {
            return encodeOrFallback(unknownResponse)
        }

        switch request {
        case .getState:
            return encodeOrFallback(GetStateResponse.success(daemon.getStatePayload()))

        case .setLimit(let value):
            daemon.setLimit(value)
            return encodeOrFallback(AckResponse.success(EmptyPayload()))

        case .setConfig(let config):
            daemon.setConfig(config)
            return encodeOrFallback(AckResponse.success(EmptyPayload()))

        case .getConfig:
            return encodeOrFallback(GetConfigResponse.success(daemon.getConfig()))

        case .action(let name):
            switch daemon.performAction(name) {
            case .success:
                return encodeOrFallback(AckResponse.success(EmptyPayload()))
            case .failure(let message):
                return encodeOrFallback(AckResponse.failure(message))
            }

        case .getStats(let hours):
            return encodeOrFallback(GetStatsResponse.success(daemon.getStats(hours: hours)))

        case .unknown(let cmd):
            // Unreachable in practice — `unknownCommandResponse` above
            // already handles every `.unknown` case — but the switch must
            // stay exhaustive.
            return encodeOrFallback(AckResponse.failure("unknown cmd: \(cmd)"))
        }
    }

    private static func encodeOrFallback<T: Encodable>(_ value: T) -> String {
        (try? ProtocolCodec.encodeLine(value)) ?? #"{"ok":false,"error":"encode failure"}"#
    }
}
