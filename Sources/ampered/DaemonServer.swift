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
// Thread-safety: `SocketServer`'s handler runs on its own internal dispatch
// queue(s), potentially concurrently with the daemon's own timer/signal/
// power-notification callbacks (all of which run on the main thread/queue —
// see `Daemon.run()`). Every handler invocation is routed through
// `DispatchQueue.main.sync` so all daemon state access is serialized on the
// same thread, with no additional locking needed anywhere in `Daemon`.
//

import AmpereCore
import Dispatch
import Foundation

/// Socket server for the daemon's control protocol (SPEC §3.1). Thin glue:
/// decode a request line, call the matching `Daemon` method (on the main
/// queue), encode the response line.
public final class DaemonServer {
    /// SPEC §3: `/var/run/ampere.sock`, mode `0660`.
    public static let defaultSocketPath = "/var/run/ampere.sock"
    public static let defaultMode: mode_t = 0o660

    private let server: SocketServer

    public init(daemon: Daemon, path: String = DaemonServer.defaultSocketPath) {
        self.server = SocketServer(path: path, mode: DaemonServer.defaultMode) { line in
            DispatchQueue.main.sync {
                DaemonServer.handle(line, daemon: daemon)
            }
        }
    }

    /// Starts accepting connections (SPEC §3.1). Throws if the socket can't
    /// be created/bound.
    public func start() throws {
        try server.start()
    }

    /// Stops accepting connections, closes existing ones, and removes the
    /// socket file — called from the daemon's signal-restore path.
    public func stop() {
        server.stop()
    }

    // MARK: - Request handling (runs on the daemon's main queue)

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

        case .getStats:
            return encodeOrFallback(GetStatsResponse.success(daemon.getStats()))

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
