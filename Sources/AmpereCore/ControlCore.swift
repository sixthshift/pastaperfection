import Foundation

/// Hardware-facing commands `decide(...)` can emit (SPEC §3.3). These are the
/// only vocabulary the daemon's SMC adapter needs to understand; `decide`
/// itself never touches IOKit.
public enum ChargingCommand: Equatable, Hashable, Sendable {
    case allowCharging
    case inhibitCharging
    case disableAdapter
    case enableAdapter
}

/// The calibration one-shot state machine (SPEC §3.3, §5 Phase 4:
/// discharge(→15) → charge(→100) → hold(1 h) → done). `decide(...)` drives
/// every transition purely off the `now` passed to it — there are no timers
/// anywhere in this type or in `decide`.
public struct CalibrationState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case discharge
        case charge
        case hold
        case done
    }

    public var phase: Phase
    /// When the current `phase` was entered. Bookkeeping only; `decide`
    /// doesn't currently read it for anything but `hold` relies on
    /// `holdStartedAt` instead so it survives independent of phase re-entry.
    public var phaseEnteredAt: Date
    /// Set the moment `phase` becomes `.hold`; `decide` compares `now`
    /// against `holdStartedAt + 1 hour` to detect hold completion. `nil`
    /// before hold is reached.
    public var holdStartedAt: Date?

    public init(phase: Phase, phaseEnteredAt: Date, holdStartedAt: Date? = nil) {
        self.phase = phase
        self.phaseEnteredAt = phaseEnteredAt
        self.holdStartedAt = holdStartedAt
    }
}

/// Everything `decide(...)` needs to remember between calls: the current
/// one-shot mode, hysteresis/idempotence bookkeeping, and a calibration
/// placeholder (SPEC §3.3).
public struct ControlState: Equatable, Sendable {
    /// The currently active one-shot action, if any. `.none` means ordinary
    /// limit/sailing mode governs charging.
    public enum OneShotMode: String, Equatable, Sendable {
        case none
        case discharging
        case toppingUp
    }

    public var oneShotMode: OneShotMode

    /// Whether heat protection is *currently* the active reason charging is
    /// inhibited. Tracked separately from `lastCommands` so heat's own
    /// hysteresis (release at `heatThresholdC - 2`) can be evaluated
    /// independently of the limit/sailing hysteresis band.
    public var heatInhibited: Bool

    /// Snapshot of the currently-applied hardware state, doing double duty
    /// as (a) the "keep previous" memory for limit/sailing hysteresis and
    /// (b) idempotence bookkeeping: `decide` only emits a command when it
    /// would change one of these memberships.
    ///
    /// Invariant: contains at most one of `{.allowCharging, .inhibitCharging}`
    /// and at most one of `{.disableAdapter, .enableAdapter}`.
    public var lastCommands: Set<ChargingCommand>

    /// The in-progress calibration one-shot (SPEC §3.3, Phase 4), or `nil`
    /// when calibration isn't running and ordinary limit/sailing/heat/
    /// one-shot rules govern charging.
    public var calibration: CalibrationState?

    /// Stamped with `now` whenever `decide` actually emits `.enableAdapter`
    /// (a real hardware-state transition, not a no-op re-assertion); `nil`
    /// once `.disableAdapter` is emitted, and `nil` initially. Backs the
    /// self-induced-unplug suppression's 10 s settle window (SPEC §3.3,
    /// amended 2026-07-06): IOKit takes a moment to re-report `AC` after the
    /// adapter is re-enabled, so a persisting `externalConnected == false`
    /// isn't treated as a genuine unplug until this window has elapsed.
    public var adapterEnabledAt: Date?

    public init(
        oneShotMode: OneShotMode = .none,
        heatInhibited: Bool = false,
        lastCommands: Set<ChargingCommand> = [.allowCharging, .enableAdapter],
        calibration: CalibrationState? = nil,
        adapterEnabledAt: Date? = nil
    ) {
        self.oneShotMode = oneShotMode
        self.heatInhibited = heatInhibited
        self.lastCommands = lastCommands
        self.calibration = calibration
        self.adapterEnabledAt = adapterEnabledAt
    }

    /// Whether charging is currently commanded inhibited, per `lastCommands`.
    public var isChargingInhibited: Bool {
        lastCommands.contains(.inhibitCharging)
    }

    /// Whether the adapter is currently commanded disabled, per `lastCommands`.
    public var isAdapterDisabled: Bool {
        lastCommands.contains(.disableAdapter)
    }

    /// The explicit, public way to represent a user-requested calibration
    /// abort (SPEC §3.3, §5 Phase 4 `calibrate-abort`): the daemon calls this
    /// on the persisted `ControlState` and feeds the result into the next
    /// `decide(...)` call. Clearing `calibration` is all that's required —
    /// `decide` already restores limit mode and re-enables the adapter
    /// idempotently from ordinary `.none`/limit-mode bookkeeping once
    /// calibration is no longer set, from any phase it was aborted in.
    public func abortingCalibration() -> ControlState {
        var copy = self
        copy.calibration = nil
        return copy
    }
}

/// The pure control core (SPEC §3.3, locked). Given the current battery
/// reading, config, and prior `ControlState`, decides which hardware
/// commands (if any) to apply and the next `ControlState` to persist.
///
/// Pure logic only — no IOKit, no I/O, no glob mutable state. The daemon is
/// a thin shell: read battery → `decide` → apply `commands` via the SMC
/// adapter idempotently → persist `next`.
public func decide(
    _ battery: BatteryState,
    _ config: Config,
    _ state: ControlState,
    now: Date
) -> (commands: [ChargingCommand], next: ControlState) {
    var next = state
    var commands: [ChargingCommand] = []
    var lastCommands = state.lastCommands
    var adapterEnabledAt = state.adapterEnabledAt

    // Only emit a command when it would actually change the recorded
    // hardware state (idempotence) — and record the change either way so
    // "keep previous" hysteresis bookkeeping stays accurate.
    func emitCharging(inhibited: Bool) {
        guard lastCommands.contains(.inhibitCharging) != inhibited else { return }
        lastCommands.remove(.allowCharging)
        lastCommands.remove(.inhibitCharging)
        let command: ChargingCommand = inhibited ? .inhibitCharging : .allowCharging
        lastCommands.insert(command)
        commands.append(command)
    }

    func emitAdapter(disabled: Bool) {
        guard lastCommands.contains(.disableAdapter) != disabled else { return }
        lastCommands.remove(.enableAdapter)
        lastCommands.remove(.disableAdapter)
        let command: ChargingCommand = disabled ? .disableAdapter : .enableAdapter
        lastCommands.insert(command)
        commands.append(command)
        // Stamp the settle-window anchor on a real enable transition; clear
        // it on disable — there's nothing to "settle" while we're the ones
        // holding the adapter off (SPEC §3.3 amended 2026-07-06).
        adapterEnabledAt = disabled ? nil : now
    }

    // `mode == "off"`: the daemon touches nothing except restoring the
    // stock-Mac safe state once (charging allowed, adapter enabled), then
    // goes quiet. Idempotence above makes this naturally "once": once both
    // memberships already reflect the safe state, no further commands emit.
    if config.mode == "off" {
        emitCharging(inhibited: false)
        emitAdapter(disabled: false)
        next.oneShotMode = .none
        next.heatInhibited = false
        next.lastCommands = lastCommands
        next.adapterEnabledAt = adapterEnabledAt
        return (commands, next)
    }

    // Self-induced-unplug suppression (SPEC §3.3, amended 2026-07-06,
    // user-approved): disabling the adapter makes macOS report
    // `externalConnected == false` — that's the *expected* consequence of
    // our own switch, not a pulled cable, and macOS cannot tell the
    // difference. So when we ourselves have the adapter asserted off
    // (`lastCommands` contains `.disableAdapter`), or we very recently
    // (re-)enabled it and IOKit hasn't caught up yet (10 s settle window,
    // anchored on `adapterEnabledAt`), a false `externalConnected` must NOT
    // trigger the unplug rules below — active modes keep driving normally
    // (calibration keeps its phase and keeps emitting per-phase commands;
    // the discharge one-shot keeps discharging), falling through to the
    // ordinary logic below exactly as if power were connected. The 20%/15%
    // floors remain the safety net throughout. Only a persisting disconnect
    // with the adapter enabled and the settle window expired is a genuine
    // unplug.
    let adapterAssertedOff = lastCommands.contains(.disableAdapter)
    let settleWindowActive: Bool = {
        guard let enabledAt = adapterEnabledAt else { return false }
        return now.timeIntervalSince(enabledAt) < 10
    }()
    let suppressUnplug = adapterAssertedOff || settleWindowActive

    // Genuine unplug: no external power, and it isn't explained by our own
    // adapter-off assertion or a still-settling re-enable. A discharge
    // one-shot has nothing left to accomplish (the Mac is already running
    // on battery), so it cancels back to limit mode. Top-up is left as-is —
    // nothing in SPEC §3.3 says unplugging should cancel it. Calibration
    // aborts too, in any phase (SPEC §3.3 abort semantics): clearing
    // `calibration` and re-enabling the adapter here is the "immediate
    // restore"; ordinary `.none`/limit-mode bookkeeping (below, on a later
    // call once power is back) takes it the rest of the way.
    if !battery.externalConnected && !suppressUnplug {
        if next.oneShotMode == .discharging {
            next.oneShotMode = .none
        }
        if next.calibration != nil {
            next.calibration = nil
            emitAdapter(disabled: false)
        }
        next.lastCommands = lastCommands
        next.adapterEnabledAt = adapterEnabledAt
        return (commands, next)
    }

    // Heat protection: its own hysteresis band, evaluated independent of
    // everything else below. While active it forces charging inhibited,
    // overriding limit/sailing hysteresis and one-shot modes alike —
    // including calibration's charge/hold phases (heat always wins for
    // charging; it does not abort calibration, so the phase itself is left
    // untouched below).
    if config.heatProtectionEnabled {
        if battery.temperatureC >= config.heatThresholdC {
            next.heatInhibited = true
        } else if battery.temperatureC <= config.heatThresholdC - 2 {
            next.heatInhibited = false
        }
        // else: between bounds — keep whatever `next.heatInhibited` already
        // was (it started as a copy of `state.heatInhibited`).
    } else {
        next.heatInhibited = false
    }

    // Calibration (SPEC §3.3, §5 Phase 4): while running, it drives the
    // decision instead of the one-shot/limit switch below. Every phase
    // advance is evaluated purely from `battery.percent` and `now` on this
    // call — no timers, no background scheduling.
    if var calibration = next.calibration {
        switch calibration.phase {
        case .discharge:
            // Floor 15%: at or under 15 move on to charge — covers both the
            // exact floor and any overshoot below it (e.g. 14). Never wait
            // for a lower percent; the battery must never be driven deeper.
            if battery.percent <= 15 {
                calibration.phase = .charge
                calibration.phaseEnteredAt = now
            }
        case .charge:
            if battery.percent >= 100 {
                calibration.phase = .hold
                calibration.phaseEnteredAt = now
                calibration.holdStartedAt = now
            }
        case .hold:
            if let holdStartedAt = calibration.holdStartedAt,
               now.timeIntervalSince(holdStartedAt) >= 3600 {
                calibration.phase = .done
            }
        case .done:
            break
        }

        if calibration.phase == .done {
            // Calibration complete: hand off to ordinary limit-mode rules
            // on this very call — no waiting for a further tick.
            next.calibration = nil
            next.oneShotMode = .none
        } else {
            next.calibration = calibration
            switch calibration.phase {
            case .discharge:
                // Adapter off and charging explicitly marked inhibited: the
                // Mac runs purely on battery, so both hardware keys agree.
                emitAdapter(disabled: true)
                emitCharging(inhibited: true)
            case .charge, .hold:
                emitAdapter(disabled: false)
                // Heat always wins for charging, even mid-calibration; it
                // never changes `calibration.phase` itself (handled above).
                emitCharging(inhibited: next.heatInhibited)
            case .done:
                break // unreachable — handled above
            }
            next.lastCommands = lastCommands
            next.adapterEnabledAt = adapterEnabledAt
            return (commands, next)
        }
    }

    if next.heatInhibited {
        emitCharging(inhibited: true)
        next.lastCommands = lastCommands
        next.adapterEnabledAt = adapterEnabledAt
        return (commands, next)
    }

    switch next.oneShotMode {
    case .discharging:
        if battery.percent < 20 {
            // Hard floor: never let the battery run below 20% — abort the
            // one-shot and restore normal charging immediately.
            emitAdapter(disabled: false)
            emitCharging(inhibited: false)
            next.oneShotMode = .none
        } else if battery.percent <= config.limitPercent {
            emitAdapter(disabled: false)
            next.oneShotMode = .none
        } else {
            emitAdapter(disabled: true)
        }

    case .toppingUp:
        let complete = battery.percent >= 100
            || (!battery.isCharging && battery.percent >= 99)
        if complete {
            next.oneShotMode = .none
        } else {
            emitCharging(inhibited: false)
        }

    case .none:
        let resumeFloor = config.sailingEnabled
            ? config.limitPercent - config.sailingOffset
            : config.limitPercent - 5

        if battery.percent >= config.limitPercent {
            emitCharging(inhibited: true)
        } else if battery.percent <= resumeFloor {
            emitCharging(inhibited: false)
        }
        // else: between bounds — keep previous inhibit state (no-op).

        // Defensive: limit/sailing mode never disables the adapter. If state
        // somehow carries a disabled adapter (e.g. after an external
        // reset), restore it rather than leaving the Mac stuck off-adapter
        // (SPEC §1: every failure path ends with charging enabled).
        emitAdapter(disabled: false)
    }

    next.lastCommands = lastCommands
    next.adapterEnabledAt = adapterEnabledAt
    return (commands, next)
}
