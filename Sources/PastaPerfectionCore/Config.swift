import Foundation

/// PastaPerfection configuration model — SPEC §3.2.
///
/// All fields must decode with defaults when absent, so old (or partial)
/// config files on disk never fail to parse as the schema grows. This is
/// implemented by hand-rolling `init(from:)` with `decodeIfPresent` rather
/// than relying on synthesized `Decodable` conformance.
public struct Config: Codable, Equatable, Sendable {
    /// Charge limit, percent. Clamp with `settingLimit(_:)` before assigning
    /// if the source is untrusted (e.g. a socket command).
    public var limitPercent: Int
    /// Sailing mode: drain to `limitPercent - sailingOffset` before resuming
    /// charge, instead of holding at the limit.
    public var sailingEnabled: Bool
    /// Offset below `limitPercent` used as the resume floor when sailing.
    public var sailingOffset: Int
    /// Pause charging while battery temperature >= `heatThresholdC`.
    public var heatProtectionEnabled: Bool
    /// Heat protection threshold, degrees Celsius.
    public var heatThresholdC: Double
    /// Run calibration automatically once a month.
    public var calibrationScheduleEnabled: Bool
    /// Day of month (1-based) on which the scheduled calibration runs.
    public var calibrationDayOfMonth: Int
    /// `"limit"` (daemon manages charging per limit rules) or `"off"`
    /// (daemon touches nothing). One-shot states (discharging, topping-up,
    /// calibrating) are runtime-only and never persisted here.
    public var mode: String

    public static let defaultLimitPercent = 80
    public static let defaultSailingEnabled = false
    public static let defaultSailingOffset = 5
    public static let defaultHeatProtectionEnabled = true
    public static let defaultHeatThresholdC = 35.0
    public static let defaultCalibrationScheduleEnabled = false
    public static let defaultCalibrationDayOfMonth = 1
    public static let defaultMode = "limit"

    public init(
        limitPercent: Int = defaultLimitPercent,
        sailingEnabled: Bool = defaultSailingEnabled,
        sailingOffset: Int = defaultSailingOffset,
        heatProtectionEnabled: Bool = defaultHeatProtectionEnabled,
        heatThresholdC: Double = defaultHeatThresholdC,
        calibrationScheduleEnabled: Bool = defaultCalibrationScheduleEnabled,
        calibrationDayOfMonth: Int = defaultCalibrationDayOfMonth,
        mode: String = defaultMode
    ) {
        self.limitPercent = limitPercent
        self.sailingEnabled = sailingEnabled
        self.sailingOffset = sailingOffset
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatThresholdC = heatThresholdC
        self.calibrationScheduleEnabled = calibrationScheduleEnabled
        self.calibrationDayOfMonth = calibrationDayOfMonth
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case limitPercent, sailingEnabled, sailingOffset, heatProtectionEnabled,
             heatThresholdC, calibrationScheduleEnabled, calibrationDayOfMonth, mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitPercent = try container.decodeIfPresent(Int.self, forKey: .limitPercent)
            ?? Self.defaultLimitPercent
        sailingEnabled = try container.decodeIfPresent(Bool.self, forKey: .sailingEnabled)
            ?? Self.defaultSailingEnabled
        sailingOffset = try container.decodeIfPresent(Int.self, forKey: .sailingOffset)
            ?? Self.defaultSailingOffset
        heatProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled)
            ?? Self.defaultHeatProtectionEnabled
        heatThresholdC = try container.decodeIfPresent(Double.self, forKey: .heatThresholdC)
            ?? Self.defaultHeatThresholdC
        calibrationScheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .calibrationScheduleEnabled)
            ?? Self.defaultCalibrationScheduleEnabled
        calibrationDayOfMonth = try container.decodeIfPresent(Int.self, forKey: .calibrationDayOfMonth)
            ?? Self.defaultCalibrationDayOfMonth
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
            ?? Self.defaultMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limitPercent, forKey: .limitPercent)
        try container.encode(sailingEnabled, forKey: .sailingEnabled)
        try container.encode(sailingOffset, forKey: .sailingOffset)
        try container.encode(heatProtectionEnabled, forKey: .heatProtectionEnabled)
        try container.encode(heatThresholdC, forKey: .heatThresholdC)
        try container.encode(calibrationScheduleEnabled, forKey: .calibrationScheduleEnabled)
        try container.encode(calibrationDayOfMonth, forKey: .calibrationDayOfMonth)
        try container.encode(mode, forKey: .mode)
    }

    /// Clamp a requested charge limit to the allowed range (SPEC §1: 50-100).
    public static func settingLimit(_ value: Int) -> Int {
        min(max(value, 50), 100)
    }

    /// Load config from `url`, decoding with defaults for any missing field.
    /// Throws if the file is missing or its contents are not valid JSON.
    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Save config to `url` as an atomic write (via a temp file + rename, so
    /// readers never observe a partially-written file).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
