import Foundation
import AmpereCore

/// View model for the menu bar app's daemon connection (Phase 2 / SPEC §3).
/// Polls `get-state` over `SocketClient` every 5 s, plus immediately on
/// popover open (`refresh()`), and publishes a `ViewState` the UI renders
/// directly. All socket I/O runs off the main thread (`Task.detached`) so the
/// 5 s cadence never blocks SwiftUI; connection-refused/timeouts/any error
/// resolve to `.daemonUnavailable` rather than throwing or crashing.
@MainActor
public final class DaemonClientModel: ObservableObject {
    /// Everything the UI needs to render: either the daemon couldn't be
    /// reached, or the last successfully fetched state.
    public enum ViewState: Equatable, Sendable {
        case daemonUnavailable
        case state(GetStatePayload)
    }

    /// Default per SPEC §3: `/var/run/ampere.sock`.
    public static let defaultSocketPath = "/var/run/ampere.sock"
    /// Default poll cadence (this ticket): 5 s.
    public static let defaultPollInterval: TimeInterval = 5.0

    @Published public private(set) var viewState: ViewState = .daemonUnavailable

    private let socketPath: String
    private let pollInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private var timer: Timer?

    public init(
        socketPath: String = "/var/run/ampere.sock",
        pollInterval: TimeInterval = 5.0,
        requestTimeout: TimeInterval = 2.0,
        autoStart: Bool = true
    ) {
        self.socketPath = socketPath
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        if autoStart {
            start()
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts the 5 s poll timer (idempotent) and fires an immediate refresh.
    /// Safe to call again (e.g. on popover open) — it just re-fires
    /// `refresh()` without creating a second timer.
    public func start() {
        refresh()
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Fetches `get-state` once, off the main thread, and publishes the
    /// result. Called on the 5 s cadence and immediately when the popover
    /// opens (`MenuBarView.onAppear`).
    public func refresh() {
        let path = socketPath
        let timeout = requestTimeout
        Task.detached {
            let result = Self.fetchState(socketPath: path, timeout: timeout)
            await MainActor.run { [weak self] in
                self?.viewState = result
            }
        }
    }

    /// Pure-ish socket round trip: connect, send `get-state`, decode the
    /// response. Any failure (socket absent, connection refused, timeout,
    /// malformed response, `ok == false`) maps to `.daemonUnavailable` —
    /// never throws out of this function.
    nonisolated private static func fetchState(socketPath: String, timeout: TimeInterval) -> ViewState {
        let client = SocketClient()
        defer { client.close() }
        do {
            try client.connect(path: socketPath)
            let requestLine = try ProtocolCodec.encodeLine(Request.getState)
            let responseLine = try client.request(requestLine, timeout: timeout)
            let response = try ProtocolCodec.decode(GetStateResponse.self, from: responseLine)
            guard response.ok, let data = response.data else {
                return .daemonUnavailable
            }
            return .state(data)
        } catch {
            return .daemonUnavailable
        }
    }
}
