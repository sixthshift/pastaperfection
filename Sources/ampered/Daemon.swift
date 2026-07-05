//
// Daemon.swift
// ampered
//
// The root daemon's event loop (SPEC §3, §5 Phase 1): read battery state ->
// the pure `decide(...)` control core -> apply commands via `SMCAdapter`.
// No socket server yet (a later ticket adds it) — this ticket is the loop,
// config load/create, event sources, and signal-restore only.
//
// Failure philosophy (SPEC §1, locked): every exit path restores charging
// and the adapter to the stock-Mac safe state before the process exits.
//

import AmpereCore
import Darwin
import Dispatch
import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Sidecar persistence for the monthly calibration schedule's last-fired
/// date (SPEC §3.2 `calibrationScheduleEnabled`/`calibrationDayOfMonth`, §5
/// Phase 4: fire "at most once per month"). `Config.swift` is not in this
/// ticket's files contract, so this one field lives in its own tiny JSON
/// file rather than in the config model; the URL is injectable (matching
/// `Daemon`'s `configURL`/`telemetryURL` pattern) so it's inspectable by
/// tests-by-inspection without touching the real filesystem path.
struct CalibrationScheduleState: Codable, Equatable {
    /// ISO 8601 timestamp of the last time the monthly schedule auto-started
    /// calibration; `nil` if it never has.
    var lastCalibrationDate: String?

    static func load(from url: URL) -> CalibrationScheduleState {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CalibrationScheduleState.self, from: data)
        else {
            return CalibrationScheduleState(lastCalibrationDate: nil)
        }
        return decoded
    }

    func save(to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Thin shell around the pure control core: 30 s poll timer + power-source
/// change notifications + sleep/wake notifications, each triggering
/// read -> `decide(...)` -> `adapter.apply(...)`. SIGTERM/SIGINT restore
/// charging + adapter and exit 0 (SPEC §1, §3 — locked).
public final class Daemon {
    public typealias Reader = () -> BatteryReading

    /// Default location of the daemon's config file (SPEC §3).
    public static let defaultConfigURL = URL(fileURLWithPath: "/Library/Application Support/Ampere/config.json")

    /// Default location of the telemetry log (SPEC §3).
    public static let defaultTelemetryURL = URL(fileURLWithPath: "/Library/Application Support/Ampere/telemetry.jsonl")

    /// Default location of the monthly-calibration-schedule sidecar (see
    /// `CalibrationScheduleState` above for why this isn't in `config.json`).
    public static let defaultCalibrationScheduleURL = URL(fileURLWithPath: "/Library/Application Support/Ampere/calibration-state.json")

    private let reader: Reader
    private let adapter: SMCAdapter
    private let configURL: URL
    private let calibrationScheduleURL: URL
    private let telemetryLog: TelemetryLog

    private var config: Config
    private var state = ControlState()
    /// Most recent battery reading, refreshed on every `evaluate()`. Backs
    /// `get-state`'s live fields (SPEC §3.1) between poll ticks.
    private var lastReading: BatteryReading = BatteryReader.parse([:])
    /// Counts 30 s poll timer ticks so telemetry samples at every other tick
    /// (SPEC §3: 60 s cadence) rather than every 30 s poll.
    private var timerTickCount = 0
    /// Persisted "last time the monthly schedule auto-started calibration"
    /// (SPEC §5 Phase 4). Loaded once at init, rewritten only when the
    /// schedule actually fires.
    private var calibrationSchedule: CalibrationScheduleState
    /// Wall-clock time of the last monthly-schedule check; `nil` means
    /// "never checked yet, check now". Used to throttle the check to at
    /// most once per hour despite piggybacking on the 30 s poll timer.
    private var lastCalibrationCheckAt: Date?

    private var timerSource: DispatchSourceTimer?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?
    private var daemonServer: DaemonServer?

    // IOKit power notification plumbing, kept alive for the process lifetime
    // (their run loop sources only fire while these are retained).
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerConnect: io_connect_t = 0
    private var psRunLoopSource: Unmanaged<CFRunLoopSource>?

    /// `reader`/`adapter` are injectable (compile-safety / testability);
    /// `run()` always uses whatever this instance was built with, which —
    /// when the daemon is started for real via `main.swift` — is always the
    /// live defaults below (nothing overrides them in production).
    public init(
        configURL: URL = Daemon.defaultConfigURL,
        telemetryURL: URL = Daemon.defaultTelemetryURL,
        calibrationScheduleURL: URL = Daemon.defaultCalibrationScheduleURL,
        reader: @escaping Reader = { BatteryReader.readLive() },
        adapter: SMCAdapter = Daemon.liveAdapter()
    ) {
        self.configURL = configURL
        self.calibrationScheduleURL = calibrationScheduleURL
        self.reader = reader
        self.adapter = adapter
        self.config = Daemon.loadOrCreateConfig(at: configURL)
        self.telemetryLog = TelemetryLog(url: telemetryURL)
        self.calibrationSchedule = CalibrationScheduleState.load(from: calibrationScheduleURL)
    }

    /// Builds the live SMC-backed adapter, opening the hardware connection
    /// best-effort. A failed `open()` still yields a usable adapter whose
    /// writes simply fail probe/verify rather than crash the daemon —
    /// consistent with SPEC §1: a daemon that can't reach SMC does nothing,
    /// rather than doing something wrong.
    public static func liveAdapter() -> SMCAdapter {
        let smc = SMC()
        do {
            try smc.open()
        } catch {
            FileHandle.standardError.write(Data("ampered: warning: failed to open SMC connection: \(error)\n".utf8))
        }
        return SMCAdapter(writer: smc, readBattery: { BatteryReader.readLive().state })
    }

    /// Loads config from `url`; if missing/unreadable, creates the
    /// containing directory and writes the default config, then returns it
    /// (SPEC §3: "daemon owns writes").
    public static func loadOrCreateConfig(at url: URL) -> Config {
        if let existing = try? Config.load(from: url) {
            return existing
        }
        let defaults = Config()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaults.save(to: url)
        return defaults
    }

    // MARK: Run loop

    /// Runs the daemon forever (until a signal exits the process). Installs
    /// signal handling and power notifications, evaluates once immediately,
    /// starts the 30 s poll timer, then blocks the current thread on its run
    /// loop (required for the IOKit run-loop-source notifications; the
    /// timer/signal `DispatchSource`s on the main queue integrate with it
    /// automatically).
    public func run() {
        installSignalHandlers()
        installPowerNotifications()
        evaluate()
        installTimer()
        installSocketServer()
        CFRunLoopRun()
    }

    // MARK: Evaluation (read -> decide -> apply)

    private func evaluate() {
        let reading = reader()
        lastReading = reading
        let (commands, next) = decide(reading.state, config, state, now: Date())
        adapter.apply(commands)
        state = next
    }

    // MARK: Socket server (SPEC §3, §3.1)

    /// Starts `DaemonServer` at `/var/run/ampere.sock` after the rest of
    /// setup (config load, first `evaluate()`, timer) is in place. A failure
    /// here is logged, not fatal — SPEC §1's safe-state invariant already
    /// holds via `evaluate()`/signal handling regardless of whether the
    /// socket is reachable.
    private func installSocketServer() {
        let server = DaemonServer(daemon: self)
        do {
            try server.start()
            daemonServer = server
        } catch {
            FileHandle.standardError.write(Data("ampered: warning: failed to start socket server: \(error)\n".utf8))
        }
    }

    // MARK: Timer (30 s poll, SPEC §3)

    private func installTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.handleTimerTick()
        }
        timer.resume()
        timerSource = timer
    }

    /// Every 30 s tick re-evaluates; every *other* tick (60 s cadence, SPEC
    /// §3: "one sample/60 s") also appends a telemetry sample; every tick
    /// also considers the monthly calibration schedule (throttled to at most
    /// once per hour internally — see `checkCalibrationSchedule`).
    private func handleTimerTick() {
        evaluate()
        timerTickCount += 1
        if timerTickCount % 2 == 0 {
            sampleTelemetry()
        }
        checkCalibrationSchedule()
    }

    // MARK: Monthly calibration schedule (SPEC §3.2, §5 Phase 4)

    /// Auto-starts calibration when `config.calibrationScheduleEnabled`,
    /// today's day-of-month matches `config.calibrationDayOfMonth`, a
    /// charger is attached, and calibration isn't already running — at most
    /// once per calendar month (persisted via `calibrationSchedule`).
    /// Piggybacks on the 30 s poll timer but only actually runs its checks
    /// once per hour (day-of-month granularity never needs finer
    /// resolution) via `lastCalibrationCheckAt`.
    private func checkCalibrationSchedule(now: Date = Date()) {
        if let last = lastCalibrationCheckAt, now.timeIntervalSince(last) < 3600 {
            return
        }
        lastCalibrationCheckAt = now

        guard config.calibrationScheduleEnabled else { return }

        let calendar = Calendar(identifier: .gregorian)
        guard calendar.component(.day, from: now) == config.calibrationDayOfMonth else { return }
        guard lastReading.externalConnected else { return }
        guard state.calibration == nil else { return }

        if let lastDateString = calibrationSchedule.lastCalibrationDate,
           let lastDate = ISO8601DateFormatter().date(from: lastDateString),
           calendar.isDate(lastDate, equalTo: now, toGranularity: .month) {
            // Already fired this month.
            return
        }

        state.calibration = CalibrationState(phase: .discharge, phaseEnteredAt: now)
        calibrationSchedule.lastCalibrationDate = ISO8601DateFormatter().string(from: now)
        calibrationSchedule.save(to: calibrationScheduleURL)
        evaluate()
    }

    /// Appends the current battery reading + charging-paused state to the
    /// telemetry log (SPEC §3, §5 Phase 3).
    private func sampleTelemetry() {
        let reading = lastReading
        let sample = TelemetrySample(
            ts: Date(),
            percent: reading.percent,
            isCharging: reading.isCharging,
            temperatureC: reading.temperatureC,
            amperageMA: reading.amperageMA,
            voltageMV: reading.voltageMV,
            chargingPaused: state.isChargingInhibited
        )
        telemetryLog.append(sample)
    }

    // MARK: Power notifications (SPEC §3: power-source changes + sleep/wake)

    /// Power-source change notifications (`IOPSNotificationCreateRunLoopSource`)
    /// — re-evaluate immediately on any change (adapter plug/unplug, etc.).
    private func installPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue()
            daemon.evaluate()
        }, context) else {
            return
        }
        psRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source.takeUnretainedValue(), .commonModes)

        installSystemPowerNotifications()
    }

    /// Sleep/wake notifications (`IORegisterForSystemPower`): on wake,
    /// re-evaluate immediately (firmware may silently re-enable charging —
    /// SPEC §3); sleep-related messages are acknowledged via
    /// `IOAllowPowerChange` so the system isn't blocked from sleeping.
    private func installSystemPowerNotifications() {
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let connect = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
            daemon.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
        }, &notifier)

        guard connect != 0, let port = notifyPort else { return }

        powerConnect = connect
        powerNotifyPort = port
        powerNotifier = notifier

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    // The `kIOMessage*` macros in <IOKit/IOMessage.h> are marked unavailable
    // to Swift ("structure not supported" — they're untyped preprocessor
    // macros), so the raw values are reproduced here: `iokit_common_msg(m)`
    // expands to `sys_iokit | sub_iokit_common | m` = `0xE0000000 | m`
    // (`IOReturn.h`: `sys_iokit = err_system(0x38)` = `0x38 << 26` =
    // `0xE0000000`; `sub_iokit_common = err_sub(0)` = `0`).
    private static let messageCanSystemSleep: UInt32 = 0xE0000270
    private static let messageSystemWillSleep: UInt32 = 0xE0000280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE0000300

    private func handlePowerMessage(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.messageCanSystemSleep, Self.messageSystemWillSleep:
            // Acknowledge so the system isn't blocked from sleeping; we have
            // nothing to veto here (SPEC §1's safe-state invariant already
            // holds regardless of sleep).
            if powerConnect != 0 {
                IOAllowPowerChange(powerConnect, Int(bitPattern: messageArgument))
            }
        case Self.messageSystemHasPoweredOn:
            evaluate()
        default:
            break
        }
    }

    // MARK: Signal handling (SPEC §1, §3 — locked restore-on-exit)

    private func installSignalHandlers() {
        // Ignore the default disposition so the DispatchSourceSignal below
        // actually receives the signal instead of the process dying first.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.restoreAndExit()
        }
        term.resume()
        sigTermSource = term

        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler { [weak self] in
            self?.restoreAndExit()
        }
        intr.resume()
        sigIntSource = intr
    }

    /// SPEC §1 (locked): "every failure path ends with charging enabled."
    /// Restore charging + adapter to the stock-Mac safe state, then exit 0.
    /// Explicitly clears any in-progress calibration first (SPEC §5 Phase 4:
    /// abort semantics) so this path's intent is unambiguous even though the
    /// process exits immediately after — the two direct adapter calls below
    /// already force the hardware to the safe state unconditionally, calibration
    /// running or not.
    private func restoreAndExit() -> Never {
        daemonServer?.stop()
        state = state.abortingCalibration()
        adapter.setChargingInhibited(false)
        adapter.setAdapterDisabled(false)
        exit(0)
    }

    // MARK: - Socket command handlers (SPEC §3.1), invoked by `DaemonServer`
    //
    // `DaemonServer` routes every handler call through `DispatchQueue.main
    // .sync`, and `evaluate()`/the timer/signal/power-notification callbacks
    // above all already run on the main thread/queue (SPEC §3: the daemon's
    // run loop lives there) — so these methods never race `evaluate()` or
    // each other.

    /// `get-state` (SPEC §3.1): assembled from the latest battery reading,
    /// `state`/`config`, and the adapter's write-verification canary.
    func getStatePayload() -> GetStatePayload {
        let reading = lastReading
        let paused = state.isChargingInhibited
        let pauseReason: PauseReason? = paused ? (state.heatInhibited ? .heat : .limit) : nil

        return GetStatePayload(
            percent: reading.percent,
            isCharging: reading.isCharging,
            externalConnected: reading.externalConnected,
            chargingPaused: paused,
            pauseReason: pauseReason,
            adapterDisabled: state.isAdapterDisabled,
            mode: currentModeString,
            limit: config.limitPercent,
            temperatureC: reading.temperatureC,
            health: HealthPayload(
                maxCapacity: reading.appleRawMaxCapacity,
                designCapacity: reading.designCapacity,
                cycleCount: reading.cycleCount
            ),
            calibration: state.calibration.map {
                CalibrationPayload(phase: $0.phase.rawValue, startedAt: $0.phaseEnteredAt)
            },
            writeVerified: adapter.lastWriteVerified
        )
    }

    /// The runtime `mode` string on the `get-state` payload (SPEC §3.2:
    /// one-shot states are runtime, not config): calibration and one-shot
    /// modes take priority over `config.mode` ("limit"/"off").
    private var currentModeString: String {
        if state.calibration != nil { return "calibrating" }
        switch state.oneShotMode {
        case .discharging: return "discharging"
        case .toppingUp: return "topping-up"
        case .none: return config.mode
        }
    }

    /// `set-limit` (SPEC §3.1): clamp via `Config.settingLimit`, persist,
    /// immediate re-evaluate.
    func setLimit(_ value: Int) {
        config.limitPercent = Config.settingLimit(value)
        persistConfig()
        evaluate()
    }

    /// `set-config` (SPEC §3.1): merge only the provided fields, persist,
    /// re-evaluate.
    func setConfig(_ partial: PartialConfig) {
        config = partial.merged(onto: config)
        persistConfig()
        evaluate()
    }

    /// `get-config` (SPEC §3.1).
    func getConfig() -> Config {
        config
    }

    /// Outcome of an `action` command (SPEC §3.1): success, or a clear
    /// failure message (e.g. `calibrate-start` without a charger attached).
    enum ActionOutcome {
        case success
        case failure(String)
    }

    /// `action` (SPEC §3.1): `discharge-to-limit` / `top-up` set the
    /// corresponding `ControlState.oneShotMode`; `calibrate-start` requires
    /// `externalConnected` (else `ok:false "charger required"`) and seeds
    /// calibration; `calibrate-abort` clears it. Every branch re-evaluates
    /// immediately so the new mode takes effect on this same command.
    func performAction(_ name: ActionName) -> ActionOutcome {
        switch name {
        case .dischargeToLimit:
            state.oneShotMode = .discharging
            evaluate()
            return .success
        case .topUp:
            state.oneShotMode = .toppingUp
            evaluate()
            return .success
        case .calibrateStart:
            guard lastReading.externalConnected else {
                return .failure("charger required")
            }
            state.calibration = CalibrationState(phase: .discharge, phaseEnteredAt: Date())
            evaluate()
            return .success
        case .calibrateAbort:
            state = state.abortingCalibration()
            evaluate()
            return .success
        }
    }

    /// `get-stats` (SPEC §3.1): reads persisted telemetry samples from the
    /// last `hours` hours and projects them to the wire shape (`StatsSample`).
    func getStats(hours: Int) -> StatsPayload {
        let samples = telemetryLog.read(hoursBack: Double(hours)).map { sample in
            StatsSample(
                timestamp: sample.ts,
                percent: sample.percent,
                isCharging: sample.isCharging,
                temperatureC: sample.temperatureC,
                amperageMA: sample.amperageMA,
                voltageMV: sample.voltageMV
            )
        }
        return StatsPayload(samples: samples)
    }

    private func persistConfig() {
        try? config.save(to: configURL)
    }
}
