import Foundation
import IOKit

/// Reads battery data from the `AppleSmartBattery` IORegistry service
/// (SPEC §4). `parse` is pure and injectable — tests feed it fixture
/// dictionaries directly, with no IOKit involved. The live path
/// (`readLive`) only reads the registry; it needs no root privileges.
public enum BatteryReader {
    /// SPEC §4 key names as they appear in the AppleSmartBattery service dictionary.
    private enum Key {
        static let currentCapacity = "CurrentCapacity"
        static let isCharging = "IsCharging"
        static let externalConnected = "ExternalConnected"
        static let temperature = "Temperature"
        static let cycleCount = "CycleCount"
        static let appleRawMaxCapacity = "AppleRawMaxCapacity"
        static let designCapacity = "DesignCapacity"
        static let amperage = "Amperage"
        static let voltage = "Voltage"
    }

    private static let requiredKeys: [String] = [
        Key.currentCapacity, Key.isCharging, Key.externalConnected, Key.temperature,
        Key.cycleCount, Key.appleRawMaxCapacity, Key.designCapacity, Key.amperage, Key.voltage
    ]

    /// SPEC §9.4 key names for the `AdapterDetails` sub-dictionary of the
    /// same `AppleSmartBattery` service dictionary.
    private enum AdapterKey {
        static let details = "AdapterDetails"
        static let watts = "Watts"
        static let name = "Name"
        static let description = "Description"
        static let voltage = "AdapterVoltage"
        static let current = "Current"
    }

    /// Shared `Any? -> Int?` coercion (`NSNumber` or `Int`), used by both
    /// `parse(_:)` and `parseAdapter(_:)`.
    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return nil
    }

    /// Parses a raw IORegistry-style dictionary into a `BatteryReading`.
    ///
    /// Pure and total: missing or mistyped keys fall back to sensible
    /// defaults (0 / false / 0.0) rather than throwing or crashing.
    /// `complete` is `false` whenever any SPEC §4 key was absent or not
    /// parseable as its expected type; the reading is still usable.
    public static func parse(_ dict: [String: Any]) -> BatteryReading {
        var allPresent = true
        for key in requiredKeys where dict[key] == nil {
            allPresent = false
        }

        func intValue(_ key: String) -> Int? {
            Self.intValue(dict[key])
        }

        func boolValue(_ key: String) -> Bool? {
            if let n = dict[key] as? NSNumber { return n.boolValue }
            if let b = dict[key] as? Bool { return b }
            return nil
        }

        func requiredInt(_ key: String) -> Int {
            guard let v = intValue(key) else {
                allPresent = false
                return 0
            }
            return v
        }

        func requiredBool(_ key: String) -> Bool {
            guard let v = boolValue(key) else {
                allPresent = false
                return false
            }
            return v
        }

        let percent = requiredInt(Key.currentCapacity)
        let charging = requiredBool(Key.isCharging)
        let external = requiredBool(Key.externalConnected)

        // Temperature is centi-degrees C (e.g. 3011 -> 30.11).
        let temperatureRaw: Int
        if let v = intValue(Key.temperature) {
            temperatureRaw = v
        } else {
            allPresent = false
            temperatureRaw = 0
        }
        let temperatureC = Double(temperatureRaw) / 100.0

        let cycleCount = requiredInt(Key.cycleCount)
        let appleRawMaxCapacity = requiredInt(Key.appleRawMaxCapacity)
        let designCapacity = requiredInt(Key.designCapacity)
        let amperageMA = requiredInt(Key.amperage)
        let voltageMV = requiredInt(Key.voltage)

        return BatteryReading(
            percent: percent,
            isCharging: charging,
            externalConnected: external,
            temperatureC: temperatureC,
            cycleCount: cycleCount,
            appleRawMaxCapacity: appleRawMaxCapacity,
            designCapacity: designCapacity,
            amperageMA: amperageMA,
            voltageMV: voltageMV,
            complete: allPresent
        )
    }

    /// Parses the `AdapterDetails` sub-dictionary of the same injected
    /// `AppleSmartBattery` dict (SPEC §9.4): `Watts` (`Int`) is required;
    /// `Name`, falling back to `Description`, is optional. Also reads the
    /// rated/negotiated electrical specs (SPEC §10.2): `AdapterVoltage`
    /// (millivolts) and `Current` (milliamps), each independently optional —
    /// absent or mistyped yields `nil` for that field only, never affecting
    /// `watts`/`name`. Pure and total, matching `parse(_:)`'s style — an
    /// absent `AdapterDetails` sub-dictionary, or a missing/mistyped
    /// `Watts`, both yield `nil` rather than crashing or inventing a value.
    /// Kept separate from `parse(_:)`/`BatteryReading` (whose shape is
    /// frozen — see `BatteryState.swift`) since this is an
    /// independently-optional read of the same underlying dict.
    public static func parseAdapter(_ dict: [String: Any]) -> AdapterPayload? {
        guard let details = dict[AdapterKey.details] as? [String: Any] else { return nil }
        guard let watts = intValue(details[AdapterKey.watts]) else { return nil }
        let name = (details[AdapterKey.name] as? String) ?? (details[AdapterKey.description] as? String)
        // SPEC §10.2: rated/negotiated electrical specs. Absent or mistyped
        // -> nil, never a crash; watts/name behavior is unaffected.
        let voltageMV = intValue(details[AdapterKey.voltage])
        let currentMA = intValue(details[AdapterKey.current])
        return AdapterPayload(watts: watts, name: name, voltageMV: voltageMV, currentMA: currentMA)
    }

    /// Live path: fetches the `AppleSmartBattery` IORegistry service
    /// dictionary and parses it. Read-only (`IOServiceGetMatchingService` +
    /// `IORegistryEntryCreateCFProperties`) — no root privileges required.
    /// Falls back to an empty (incomplete) reading if the service or its
    /// properties can't be obtained, never crashes.
    public static func readLive() -> BatteryReading {
        parse(liveServiceDict() ?? [:])
    }

    /// Live path for adapter details: the same `AppleSmartBattery` registry
    /// lookup as `readLive()`, parsed via `parseAdapter`. `nil` if the
    /// service/properties can't be obtained (matches `readLive()`'s
    /// never-crash fallback).
    public static func readLiveAdapter() -> AdapterPayload? {
        guard let props = liveServiceDict() else { return nil }
        return parseAdapter(props)
    }

    /// Fetches the raw `AppleSmartBattery` IORegistry service dictionary.
    /// Read-only (`IOServiceGetMatchingService` +
    /// `IORegistryEntryCreateCFProperties`) — no root privileges required.
    /// `nil` if the service or its properties can't be obtained; never
    /// crashes. Shared by `readLive()` and `readLiveAdapter()` so both read
    /// the exact same dict.
    private static func liveServiceDict() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &propsUnmanaged,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS,
              let cfProps = propsUnmanaged?.takeRetainedValue(),
              let props = cfProps as? [String: Any]
        else {
            return nil
        }

        return props
    }
}
