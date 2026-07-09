import AppKit
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
    /// Last successfully fetched `get-config` (SPEC §3.2). `nil` until the
    /// first fetch succeeds (or after a fetch failure); used by the popover
    /// (`ControlsView`) to read sailing settings, which aren't part of
    /// `GetStatePayload`. Fetched alongside `get-state` on every `refresh()`.
    @Published public private(set) var config: Config?

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
    /// `refresh()` without creating a second timer. Each recurring tick
    /// no-ops when the app has no visible window (`NSApp.occlusionState`,
    /// not `isVisible` — the latter stays true through a sleeping display or
    /// a fully-covered window, power-draw hardening, T035); this initial
    /// call and any caller-triggered `refresh()` are unaffected, since the
    /// gate lives only in the timer closure below.
    public func start() {
        refresh()
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard NSApp.occlusionState.contains(.visible) else { return }
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
            let stateResult = Self.fetchState(socketPath: path, timeout: timeout)
            let configResult = Self.fetchConfig(socketPath: path, timeout: timeout)
            await MainActor.run { [weak self] in
                self?.viewState = stateResult
                self?.config = configResult
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

    /// Pure-ish socket round trip: connect, send `get-config`, decode the
    /// response. `nil` on any failure — mirrors `fetchState`'s
    /// never-throws-out contract. `ControlsView` falls back to `Config`'s
    /// own defaults when this is `nil` (e.g. before the first successful
    /// fetch, or while the daemon is unreachable).
    nonisolated private static func fetchConfig(socketPath: String, timeout: TimeInterval) -> Config? {
        let client = SocketClient()
        defer { client.close() }
        do {
            try client.connect(path: socketPath)
            let requestLine = try ProtocolCodec.encodeLine(Request.getConfig)
            let responseLine = try client.request(requestLine, timeout: timeout)
            let response = try ProtocolCodec.decode(GetConfigResponse.self, from: responseLine)
            guard response.ok, let data = response.data else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// Fetches `get-stats` once, off the main thread (SPEC §3.1, ticket
    /// T015 — Stats window). Unlike `refresh()`'s `fetchState`/`fetchConfig`,
    /// this isn't part of the 5 s poll cadence — the Stats window calls it
    /// on demand (open + manual refresh). Returns `nil` on any failure
    /// (socket absent, connection refused, timeout, malformed response,
    /// `ok == false`) — never throws out of this method, mirroring the
    /// never-throws-out contract of `fetchState`/`fetchConfig`.
    public func getStats(hours: Int) async -> [StatsSample]? {
        let path = socketPath
        let timeout = requestTimeout
        return await Task.detached {
            Self.fetchStats(hours: hours, socketPath: path, timeout: timeout)
        }.value
    }

    /// Pure-ish socket round trip: connect, send `get-stats`, decode the
    /// response. Any failure maps to `nil` — never throws out of this
    /// function.
    nonisolated private static func fetchStats(
        hours: Int, socketPath: String, timeout: TimeInterval
    ) -> [StatsSample]? {
        let client = SocketClient()
        defer { client.close() }
        do {
            try client.connect(path: socketPath)
            let requestLine = try ProtocolCodec.encodeLine(Request.getStats(hours: hours))
            let responseLine = try client.request(requestLine, timeout: timeout)
            let response = try ProtocolCodec.decode(GetStatsResponse.self, from: responseLine)
            guard response.ok, let data = response.data else {
                return nil
            }
            return data.samples
        } catch {
            return nil
        }
    }

    /// Fetches `get-config` once, off the main thread, on demand (ticket
    /// T030 — the dashboard's sailing-mode inputs to `StatsDerived
    /// .timeEstimate`). `refresh()` already keeps `config` fresh on the 5 s
    /// poll cadence; this is for callers (the Stats window's own live-refresh
    /// timer) that want an explicit one-shot fetch without going through the
    /// full `refresh()` (which also re-fetches `get-state` and republishes
    /// `viewState`). `nil` on any failure, mirroring `getStats(hours:)`.
    public func getConfig() async -> Config? {
        let path = socketPath
        let timeout = requestTimeout
        return await Task.detached {
            Self.fetchConfig(socketPath: path, timeout: timeout)
        }.value
    }

    // MARK: - Mutations (SPEC §3.1, ticket T012)
    //
    // Every control the popover offers (limit slider, sailing toggle, mode
    // off/on, one-shot actions) goes through one of these methods — views
    // never construct `SocketClient` themselves. Each sends its request off
    // the main thread via `Task.detached` (so a slow/unavailable daemon never
    // blocks the UI), then calls `refresh()` on the main actor afterward so
    // `viewState` reflects the daemon's new authoritative state rather than
    // an optimistic local guess. Send failures are swallowed the same way
    // `fetchState` swallows them: the follow-up `refresh()` will surface
    // `.daemonUnavailable` on its own if the daemon is actually gone.

    /// Sends `set-limit` with the clamped (50-100) slider value. Callers
    /// (the slider's `onEditingChanged`) are responsible for only calling
    /// this on release, not per-tick.
    public func setLimit(_ value: Int) {
        sendAckRequest(.setLimit(value: value))
    }

    /// Sends `set-config` with a partial config patch (only the fields the
    /// caller sets are non-nil on `PartialConfig`, so unrelated config
    /// fields are left untouched by the daemon's merge).
    public func setConfig(_ config: PartialConfig) {
        sendAckRequest(.setConfig(config: config))
    }

    /// Sends a one-shot `action` command (`discharge-to-limit`, `top-up`,
    /// `calibrate-start`, `calibrate-abort`).
    public func sendAction(_ name: ActionName) {
        sendAckRequest(.action(name: name))
    }

    /// Shared plumbing for the ack-only mutation requests above: encode,
    /// send off the main thread, ignore the response body (mutations here
    /// only care whether the daemon is reachable — the follow-up `refresh()`
    /// is what actually updates `viewState`), then refresh.
    private func sendAckRequest(_ request: Request) {
        let path = socketPath
        let timeout = requestTimeout
        Task.detached {
            Self.send(request, socketPath: path, timeout: timeout)
            await MainActor.run { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Pure-ish socket round trip for a mutating request: connect, send,
    /// decode as an ack response. Never throws out of this function —
    /// failures are swallowed here because the subsequent `refresh()` is the
    /// single source of truth for whether the daemon is reachable.
    nonisolated private static func send(_ request: Request, socketPath: String, timeout: TimeInterval) {
        let client = SocketClient()
        defer { client.close() }
        do {
            try client.connect(path: socketPath)
            let requestLine = try ProtocolCodec.encodeLine(request)
            _ = try client.request(requestLine, timeout: timeout)
        } catch {
            // Swallowed: refresh() (called by the caller after this returns)
            // will resolve viewState to .daemonUnavailable if the daemon is
            // truly unreachable.
        }
    }
}
