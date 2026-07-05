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

/// Thin shell around the pure control core: 30 s poll timer + power-source
/// change notifications + sleep/wake notifications, each triggering
/// read -> `decide(...)` -> `adapter.apply(...)`. SIGTERM/SIGINT restore
/// charging + adapter and exit 0 (SPEC §1, §3 — locked).
public final class Daemon {
    public typealias Reader = () -> BatteryReading

    /// Default location of the daemon's config file (SPEC §3).
    public static let defaultConfigURL = URL(fileURLWithPath: "/Library/Application Support/Ampere/config.json")

    private let reader: Reader
    private let adapter: SMCAdapter
    private let configURL: URL

    private var config: Config
    private var state = ControlState()

    private var timerSource: DispatchSourceTimer?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?

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
        reader: @escaping Reader = { BatteryReader.readLive() },
        adapter: SMCAdapter = Daemon.liveAdapter()
    ) {
        self.configURL = configURL
        self.reader = reader
        self.adapter = adapter
        self.config = Daemon.loadOrCreateConfig(at: configURL)
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
        CFRunLoopRun()
    }

    // MARK: Evaluation (read -> decide -> apply)

    private func evaluate() {
        let reading = reader()
        let (commands, next) = decide(reading.state, config, state, now: Date())
        adapter.apply(commands)
        state = next
    }

    // MARK: Timer (30 s poll, SPEC §3)

    private func installTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.evaluate()
        }
        timer.resume()
        timerSource = timer
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
    private func restoreAndExit() -> Never {
        adapter.setChargingInhibited(false)
        adapter.setAdapterDisabled(false)
        exit(0)
    }
}
