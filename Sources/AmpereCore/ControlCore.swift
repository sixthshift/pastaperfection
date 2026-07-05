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

/// Placeholder for the calibration one-shot state machine (SPEC §3.3, §5
/// Phase 4: discharge(→15) → charge(→100) → hold(1 h) → done). `decide(...)`
/// in this ticket always treats a live `ControlState`'s `calibration` field
/// as absent (`nil`) — a later ticket implements the phase transitions,
/// floors, and abort handling, extending this same file.
public struct CalibrationState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case discharge
        case charge
        case hold
        case done
    }

    public var phase: Phase
    public var startedAt: Date
    public var phaseStartedAt: Date

    public init(phase: Phase, startedAt: Date, phaseStartedAt: Date) {
        self.phase = phase
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt
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

    /// Calibration placeholder (SPEC §3.3, Phase 4) — always `nil` in
    /// practice until a later ticket implements the state machine.
    public var calibration: CalibrationState?

    public init(
        oneShotMode: OneShotMode = .none,
        heatInhibited: Bool = false,
        lastCommands: Set<ChargingCommand> = [.allowCharging, .enableAdapter],
        calibration: CalibrationState? = nil
    ) {
        self.oneShotMode = oneShotMode
        self.heatInhibited = heatInhibited
        self.lastCommands = lastCommands
        self.calibration = calibration
    }

    /// Whether charging is currently commanded inhibited, per `lastCommands`.
    public var isChargingInhibited: Bool {
        lastCommands.contains(.inhibitCharging)
    }

    /// Whether the adapter is currently commanded disabled, per `lastCommands`.
    public var isAdapterDisabled: Bool {
        lastCommands.contains(.disableAdapter)
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
        return (commands, next)
    }

    // No external power: nothing to control. A discharge one-shot has
    // nothing left to accomplish (the Mac is already running on battery),
    // so it cancels back to limit mode. Top-up is left as-is — nothing in
    // SPEC §3.3 says unplugging should cancel it.
    guard battery.externalConnected else {
        if next.oneShotMode == .discharging {
            next.oneShotMode = .none
        }
        next.lastCommands = lastCommands
        return ([], next)
    }

    // Heat protection: its own hysteresis band, evaluated independent of
    // everything else below. While active it forces charging inhibited,
    // overriding limit/sailing hysteresis and one-shot modes alike.
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

    if next.heatInhibited {
        emitCharging(inhibited: true)
        next.lastCommands = lastCommands
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
    return (commands, next)
}
