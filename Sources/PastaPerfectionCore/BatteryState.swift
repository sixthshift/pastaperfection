import Foundation

/// Frozen battery snapshot consumed by the pure control core (SPEC §3.3).
///
/// This shape is locked — `decide(...)` and everything downstream depends on
/// exactly these four fields. Do not add fields here; extend `BatteryReading`
/// instead and project down via `BatteryReading.state`.
public struct BatteryState: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var temperatureC: Double

    public init(percent: Int, isCharging: Bool, externalConnected: Bool, temperatureC: Double) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.temperatureC = temperatureC
    }
}

/// Extended battery reading straight off the `AppleSmartBattery` IORegistry
/// service (SPEC §4 key list): the frozen `BatteryState` fields plus health /
/// telemetry data used by stats (SPEC Phase 3) and wattage calculations.
public struct BatteryReading: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var temperatureC: Double
    public var cycleCount: Int
    public var appleRawMaxCapacity: Int
    public var designCapacity: Int
    /// Signed milliamps; negative while discharging.
    public var amperageMA: Int
    public var voltageMV: Int
    /// True only when every SPEC §4 key was present in the source dictionary
    /// and parsed as its expected type. False on any missing/unreadable key —
    /// the reading itself still carries sensible defaults, never a crash.
    public var complete: Bool

    public init(
        percent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        temperatureC: Double,
        cycleCount: Int,
        appleRawMaxCapacity: Int,
        designCapacity: Int,
        amperageMA: Int,
        voltageMV: Int,
        complete: Bool
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.temperatureC = temperatureC
        self.cycleCount = cycleCount
        self.appleRawMaxCapacity = appleRawMaxCapacity
        self.designCapacity = designCapacity
        self.amperageMA = amperageMA
        self.voltageMV = voltageMV
        self.complete = complete
    }

    /// Projection down to the frozen SPEC §3.3 shape consumed by `decide(...)`.
    public var state: BatteryState {
        BatteryState(
            percent: percent,
            isCharging: isCharging,
            externalConnected: externalConnected,
            temperatureC: temperatureC
        )
    }

    /// Instantaneous power in watts: `Amperage × Voltage / 1e6` (SPEC Phase 3).
    /// Signed — negative while discharging, since `amperageMA` is signed.
    public var watts: Double {
        (Double(amperageMA) * Double(voltageMV)) / 1_000_000.0
    }
}
