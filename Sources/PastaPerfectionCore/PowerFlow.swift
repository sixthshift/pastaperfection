/// Pure, derived-logic core for the power-flow indicator (SPEC §10.4): a
/// classification of where power is currently flowing (adapter → battery,
/// adapter holding at limit, adapter only with no battery movement, or
/// battery discharge) plus the associated wattage magnitude. No IOKit, no
/// libproc, no timers — everything here is arithmetic over injected values
/// so it's fully unit-testable.

/// Classification of the current power-flow direction (SPEC §10.4).
public enum PowerFlowDirection: String, Codable, Equatable, Sendable {
    case adapterCharging
    case adapterHolding
    case adapterOnly
    case battery
}

/// A computed power-flow reading: the direction plus the battery-side flow
/// magnitude in watts (SPEC §10.4).
public struct PowerFlow: Equatable, Sendable {
    public let direction: PowerFlowDirection
    public let watts: Double

    public init(direction: PowerFlowDirection, watts: Double) {
        self.direction = direction
        self.watts = watts
    }
}

/// Pure computation of the power-flow reading (SPEC §10.4).
public enum PowerFlowCore {
    /// Derives the current `PowerFlow` from injected SMC-sourced values.
    ///
    /// Precedence (LOCKED):
    /// - `.adapterCharging` when `externalConnected && amperageMA > 0`.
    /// - `.adapterHolding` when `externalConnected && amperageMA <= 0 &&
    ///   chargingPaused`.
    /// - `.adapterOnly` when `externalConnected` and neither above matched.
    /// - `.battery` when `!externalConnected`.
    ///
    /// `watts` is always the battery-side flow magnitude, computed as
    /// `abs(amperageMA * voltageMV) / 1e6` in `Double` arithmetic so an
    /// `Int` overflow can't occur.
    public static func compute(
        externalConnected: Bool,
        isCharging: Bool,
        chargingPaused: Bool,
        amperageMA: Int,
        voltageMV: Int
    ) -> PowerFlow {
        let watts = abs(Double(amperageMA) * Double(voltageMV)) / 1e6

        let direction: PowerFlowDirection
        if externalConnected && amperageMA > 0 {
            direction = .adapterCharging
        } else if externalConnected && amperageMA <= 0 && chargingPaused {
            direction = .adapterHolding
        } else if externalConnected {
            direction = .adapterOnly
        } else {
            direction = .battery
        }

        return PowerFlow(direction: direction, watts: watts)
    }
}
