import Foundation

/// Socket protocol codec — SPEC §3.1.
///
/// JSON lines, one request line -> one response line, over
/// `/var/run/ampere.sock`. This file is a pure codec: types + encode/decode
/// helpers only. Socket I/O (server/client) is a later ticket.

// MARK: - Action names

/// `{"cmd":"action","name":...}` values (SPEC §3.1).
public enum ActionName: String, Codable, Equatable, Sendable {
    case dischargeToLimit = "discharge-to-limit"
    case topUp = "top-up"
    case calibrateStart = "calibrate-start"
    case calibrateAbort = "calibrate-abort"
}

// MARK: - Requests

/// Every request the socket protocol accepts (SPEC §3.1), plus `.unknown`
/// for any unrecognized `cmd` value — decoding never throws on a bad `cmd`,
/// it produces `.unknown` so the caller can reply with a clean error
/// response instead of dropping the connection.
public enum Request: Equatable, Sendable {
    case getState
    case setLimit(value: Int)
    case setConfig(config: PartialConfig)
    case getConfig
    case action(name: ActionName)
    case getStats(hours: Int)
    /// Decoded when `cmd` doesn't match any known command (or an `action`
    /// whose `name` isn't recognized). Carries the raw `cmd` string for the
    /// error message.
    case unknown(cmd: String)
}

extension Request: Codable {
    private enum CodingKeys: String, CodingKey {
        case cmd, value, config, name, hours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cmd = try container.decode(String.self, forKey: .cmd)
        switch cmd {
        case "get-state":
            self = .getState
        case "set-limit":
            let value = try container.decode(Int.self, forKey: .value)
            self = .setLimit(value: value)
        case "set-config":
            let config = try container.decode(PartialConfig.self, forKey: .config)
            self = .setConfig(config: config)
        case "get-config":
            self = .getConfig
        case "action":
            let rawName = try container.decode(String.self, forKey: .name)
            guard let name = ActionName(rawValue: rawName) else {
                self = .unknown(cmd: cmd)
                return
            }
            self = .action(name: name)
        case "get-stats":
            let hours = try container.decode(Int.self, forKey: .hours)
            self = .getStats(hours: hours)
        default:
            self = .unknown(cmd: cmd)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getState:
            try container.encode("get-state", forKey: .cmd)
        case .setLimit(let value):
            try container.encode("set-limit", forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setConfig(let config):
            try container.encode("set-config", forKey: .cmd)
            try container.encode(config, forKey: .config)
        case .getConfig:
            try container.encode("get-config", forKey: .cmd)
        case .action(let name):
            try container.encode("action", forKey: .cmd)
            try container.encode(name.rawValue, forKey: .name)
        case .getStats(let hours):
            try container.encode("get-stats", forKey: .cmd)
            try container.encode(hours, forKey: .hours)
        case .unknown(let cmd):
            try container.encode(cmd, forKey: .cmd)
        }
    }

    /// The canonical error response for a request that decoded to `.unknown`
    /// — `nil` for every other case. Callers use this to reply
    /// `{"ok":false,"error":"..."}` without needing their own switch.
    public var unknownCommandResponse: Response<EmptyPayload>? {
        guard case let .unknown(cmd) = self else { return nil }
        return Response(ok: false, data: nil, error: "unknown cmd: \(cmd)")
    }
}

// MARK: - Partial config (set-config payload)

/// Mirror of `Config` with every field optional, used as the `set-config`
/// payload (SPEC §3.1: "merge + persist"). Only fields present in the
/// incoming JSON are non-nil, so `merged(onto:)` overrides exactly the
/// fields the caller provided and leaves everything else untouched — unlike
/// `Config`'s own decoder, which fills every absent field with its default,
/// a partial update must be able to tell "absent" apart from "default".
public struct PartialConfig: Codable, Equatable, Sendable {
    public var limitPercent: Int?
    public var sailingEnabled: Bool?
    public var sailingOffset: Int?
    public var heatProtectionEnabled: Bool?
    public var heatThresholdC: Double?
    public var calibrationScheduleEnabled: Bool?
    public var calibrationDayOfMonth: Int?
    public var mode: String?

    public init(
        limitPercent: Int? = nil,
        sailingEnabled: Bool? = nil,
        sailingOffset: Int? = nil,
        heatProtectionEnabled: Bool? = nil,
        heatThresholdC: Double? = nil,
        calibrationScheduleEnabled: Bool? = nil,
        calibrationDayOfMonth: Int? = nil,
        mode: String? = nil
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

    /// Merge onto `base`: only fields present on `self` override; everything
    /// else keeps `base`'s value.
    public func merged(onto base: Config) -> Config {
        var result = base
        if let limitPercent { result.limitPercent = limitPercent }
        if let sailingEnabled { result.sailingEnabled = sailingEnabled }
        if let sailingOffset { result.sailingOffset = sailingOffset }
        if let heatProtectionEnabled { result.heatProtectionEnabled = heatProtectionEnabled }
        if let heatThresholdC { result.heatThresholdC = heatThresholdC }
        if let calibrationScheduleEnabled { result.calibrationScheduleEnabled = calibrationScheduleEnabled }
        if let calibrationDayOfMonth { result.calibrationDayOfMonth = calibrationDayOfMonth }
        if let mode { result.mode = mode }
        return result
    }
}

// MARK: - get-state payload

/// Battery health, as reported by `get-state` (SPEC §3.1).
public struct HealthPayload: Codable, Equatable, Sendable {
    public var maxCapacity: Int
    public var designCapacity: Int
    public var cycleCount: Int

    public init(maxCapacity: Int, designCapacity: Int, cycleCount: Int) {
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
    }
}

/// Calibration progress, as reported by `get-state` (SPEC §3.3, §5 Phase 4).
/// `nil` on the `get-state` payload when calibration isn't running.
public struct CalibrationPayload: Codable, Equatable, Sendable {
    public var phase: String
    public var startedAt: Date

    public init(phase: String, startedAt: Date) {
        self.phase = phase
        self.startedAt = startedAt
    }
}

/// Reason charging is currently paused, on the `get-state` payload.
public enum PauseReason: String, Codable, Equatable, Sendable {
    case limit
    case heat
}

/// Charging adapter details, on the `get-state` payload (SPEC §9.4): a pure
/// read of the `AdapterDetails` sub-dictionary in the `AppleSmartBattery`
/// registry entry (`BatteryReader.parseAdapter(_:)`). `nil` when no adapter
/// details are available (no adapter connected, or the registry didn't
/// expose the sub-dictionary) — Phase 5 never writes SMC keys, this is a
/// read-only projection.
public struct AdapterPayload: Equatable, Sendable {
    public var watts: Int
    public var name: String?
    /// Adapter's rated/negotiated voltage, in millivolts (SPEC §10.2). `nil`
    /// when absent from JSON (old-daemon compat) or when the registry didn't
    /// expose `AdapterVoltage`.
    public var voltageMV: Int?
    /// Adapter's rated/negotiated current, in milliamps (SPEC §10.2). `nil`
    /// when absent from JSON (old-daemon compat) or when the registry didn't
    /// expose `Current`.
    public var currentMA: Int?

    public init(watts: Int, name: String? = nil, voltageMV: Int? = nil, currentMA: Int? = nil) {
        self.watts = watts
        self.name = name
        self.voltageMV = voltageMV
        self.currentMA = currentMA
    }
}

extension AdapterPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case watts, name, voltageMV, currentMA
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watts = try container.decode(Int.self, forKey: .watts)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        voltageMV = try container.decodeIfPresent(Int.self, forKey: .voltageMV)
        currentMA = try container.decodeIfPresent(Int.self, forKey: .currentMA)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watts, forKey: .watts)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(voltageMV, forKey: .voltageMV)
        try container.encodeIfPresent(currentMA, forKey: .currentMA)
    }
}

/// `get-state`'s `data` payload (SPEC §3.1 + this ticket's amendments:
/// `pauseReason` and the `writeVerified` firmware-change canary).
///
/// `writeVerified` defaults to `true` when absent from JSON so older
/// payloads (or hand-written test fixtures) without the field still decode
/// cleanly, matching the defaulting style used by `Config`.
public struct GetStatePayload: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var chargingPaused: Bool
    /// `nil` when not paused; `"limit"` or `"heat"` when paused.
    public var pauseReason: PauseReason?
    public var adapterDisabled: Bool
    public var mode: String
    public var limit: Int
    public var temperatureC: Double
    public var health: HealthPayload
    public var calibration: CalibrationPayload?
    /// Firmware-change canary: `false` if the last SMC write was read back
    /// and had no effect (SPEC §4).
    public var writeVerified: Bool
    /// Charging adapter details (SPEC §9.4). `nil` when absent from JSON
    /// (old-daemon compat) or when the daemon has none to report (e.g. no
    /// adapter connected).
    public var adapter: AdapterPayload?

    public init(
        percent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        chargingPaused: Bool,
        pauseReason: PauseReason?,
        adapterDisabled: Bool,
        mode: String,
        limit: Int,
        temperatureC: Double,
        health: HealthPayload,
        calibration: CalibrationPayload?,
        writeVerified: Bool = true,
        adapter: AdapterPayload? = nil
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.chargingPaused = chargingPaused
        self.pauseReason = pauseReason
        self.adapterDisabled = adapterDisabled
        self.mode = mode
        self.limit = limit
        self.temperatureC = temperatureC
        self.health = health
        self.calibration = calibration
        self.writeVerified = writeVerified
        self.adapter = adapter
    }
}

extension GetStatePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case percent, isCharging, externalConnected, chargingPaused, pauseReason,
             adapterDisabled, mode, limit, temperatureC, health, calibration, writeVerified,
             adapter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percent = try container.decode(Int.self, forKey: .percent)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        externalConnected = try container.decode(Bool.self, forKey: .externalConnected)
        chargingPaused = try container.decode(Bool.self, forKey: .chargingPaused)
        pauseReason = try container.decodeIfPresent(PauseReason.self, forKey: .pauseReason)
        adapterDisabled = try container.decode(Bool.self, forKey: .adapterDisabled)
        mode = try container.decode(String.self, forKey: .mode)
        limit = try container.decode(Int.self, forKey: .limit)
        temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        health = try container.decode(HealthPayload.self, forKey: .health)
        calibration = try container.decodeIfPresent(CalibrationPayload.self, forKey: .calibration)
        writeVerified = try container.decodeIfPresent(Bool.self, forKey: .writeVerified) ?? true
        adapter = try container.decodeIfPresent(AdapterPayload.self, forKey: .adapter)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(percent, forKey: .percent)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(externalConnected, forKey: .externalConnected)
        try container.encode(chargingPaused, forKey: .chargingPaused)
        try container.encodeIfPresent(pauseReason, forKey: .pauseReason)
        try container.encode(adapterDisabled, forKey: .adapterDisabled)
        try container.encode(mode, forKey: .mode)
        try container.encode(limit, forKey: .limit)
        try container.encode(temperatureC, forKey: .temperatureC)
        try container.encode(health, forKey: .health)
        // SPEC §3.1 requires the literal `"calibration":null` on the wire
        // when calibration isn't running (clients key off its presence, not
        // just its absence) — `encodeIfPresent` would omit the key entirely,
        // so encode explicit null via `encodeNil` instead.
        if let calibration {
            try container.encode(calibration, forKey: .calibration)
        } else {
            try container.encodeNil(forKey: .calibration)
        }
        try container.encode(writeVerified, forKey: .writeVerified)
        try container.encodeIfPresent(adapter, forKey: .adapter)
    }
}

// MARK: - get-stats payload

/// One telemetry sample, as returned in `get-stats`'s `data.samples` array.
/// Field shape mirrors the frozen `BatteryState` (SPEC §3.3) plus a
/// timestamp; the telemetry sampler ticket (Phase 3) is the authority on
/// what's actually persisted to `telemetry.jsonl`; this is the wire shape
/// for handing existing samples back over the socket.
///
/// `amperageMA`/`voltageMV`/`chargingPaused` decode with a default (`0`/
/// `false`) when absent (via hand-rolled `init(from:)`, matching `Config`'s
/// defaulting style), so existing telemetry/wire payloads recorded before
/// this ticket still decode cleanly.
public struct StatsSample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var percent: Int
    public var isCharging: Bool
    public var temperatureC: Double
    /// Signed milliamps; negative while discharging. Defaults to `0` when
    /// absent from JSON.
    public var amperageMA: Int
    /// Millivolts. Defaults to `0` when absent from JSON.
    public var voltageMV: Int
    /// Whether the daemon was actively inhibiting charging (limit or heat)
    /// at sample time. Defaults to `false` when absent from JSON (old-daemon
    /// compat).
    public var chargingPaused: Bool
    /// Battery maximum capacity, in mAh (SPEC §10.3), for charting health
    /// over time. `nil` when absent from JSON (old-daemon compat, or a
    /// bucket with no non-nil capacity samples); encoded only when present.
    public var maxCapacityMAh: Int?

    public init(
        timestamp: Date,
        percent: Int,
        isCharging: Bool,
        temperatureC: Double,
        amperageMA: Int = 0,
        voltageMV: Int = 0,
        chargingPaused: Bool = false,
        maxCapacityMAh: Int? = nil
    ) {
        self.timestamp = timestamp
        self.percent = percent
        self.isCharging = isCharging
        self.temperatureC = temperatureC
        self.amperageMA = amperageMA
        self.voltageMV = voltageMV
        self.chargingPaused = chargingPaused
        self.maxCapacityMAh = maxCapacityMAh
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, percent, isCharging, temperatureC, amperageMA, voltageMV, chargingPaused, maxCapacityMAh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        percent = try container.decode(Int.self, forKey: .percent)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        amperageMA = try container.decodeIfPresent(Int.self, forKey: .amperageMA) ?? 0
        voltageMV = try container.decodeIfPresent(Int.self, forKey: .voltageMV) ?? 0
        chargingPaused = try container.decodeIfPresent(Bool.self, forKey: .chargingPaused) ?? false
        maxCapacityMAh = try container.decodeIfPresent(Int.self, forKey: .maxCapacityMAh)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(percent, forKey: .percent)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(temperatureC, forKey: .temperatureC)
        try container.encode(amperageMA, forKey: .amperageMA)
        try container.encode(voltageMV, forKey: .voltageMV)
        try container.encode(chargingPaused, forKey: .chargingPaused)
        try container.encodeIfPresent(maxCapacityMAh, forKey: .maxCapacityMAh)
    }
}

public extension StatsSample {
    /// Pure projection from `TelemetrySample` (`Telemetry.swift`'s persisted
    /// shape) to the `get-stats` wire shape. Lives in `AmpereCore` — not
    /// `Daemon.swift`, an executable target that isn't importable from tests
    /// — so it's unit-testable; `Daemon.getStats(hours:)` calls this rather
    /// than hand-rolling an equivalent field-by-field mapping.
    init(_ sample: TelemetrySample) {
        self.init(
            timestamp: sample.ts,
            percent: sample.percent,
            isCharging: sample.isCharging,
            temperatureC: sample.temperatureC,
            amperageMA: sample.amperageMA,
            voltageMV: sample.voltageMV,
            chargingPaused: sample.chargingPaused,
            maxCapacityMAh: sample.maxCapacityMAh
        )
    }
}

/// `get-stats`'s `data` payload (SPEC §3.1).
public struct StatsPayload: Codable, Equatable, Sendable {
    public var samples: [StatsSample]

    public init(samples: [StatsSample]) {
        self.samples = samples
    }
}

// MARK: - Response envelope

/// `{ok, data?, error?}` (SPEC §3.1), generic over the command's payload
/// type. Optional properties are omitted from encoded JSON when `nil`
/// (Swift's synthesized `Codable` uses `encodeIfPresent`/`decodeIfPresent`
/// for `Optional`-typed stored properties), so a success response never
/// carries a stray `"error":null` and vice versa.
public struct Response<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var ok: Bool
    public var data: Payload?
    public var error: String?

    public init(ok: Bool, data: Payload? = nil, error: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }

    public static func success(_ data: Payload) -> Response<Payload> {
        Response(ok: true, data: data, error: nil)
    }

    public static func failure(_ message: String) -> Response<Payload> {
        Response(ok: false, data: nil, error: message)
    }
}

/// Payload for responses that carry no data (e.g. acking `set-limit`,
/// `set-config`, `action`) beyond `ok`/`error`.
public struct EmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public typealias GetStateResponse = Response<GetStatePayload>
public typealias GetConfigResponse = Response<Config>
public typealias GetStatsResponse = Response<StatsPayload>
public typealias AckResponse = Response<EmptyPayload>

// MARK: - Line codec

/// JSON-lines encode/decode helpers (SPEC §3.1: "one request line -> one
/// response line"). `Date` fields (calibration `startedAt`, stats sample
/// `timestamp`) use ISO 8601 so lines stay human-readable on the wire.
public enum ProtocolCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encode any codec value (`Request` or a `Response<...>`) to a single
    /// JSON line (no trailing newline; callers append the line separator).
    public static func encodeLine<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode a single JSON line into `Request`. Never throws on an
    /// unrecognized `cmd` — that decodes to `.unknown` — but does throw if
    /// the line isn't valid JSON or is missing `cmd` entirely.
    public static func decodeRequest(from line: String) throws -> Request {
        try decoder.decode(Request.self, from: Data(line.utf8))
    }

    /// Decode a single JSON line into any other codec type (a `Response<...>`).
    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        try decoder.decode(T.self, from: Data(line.utf8))
    }
}
