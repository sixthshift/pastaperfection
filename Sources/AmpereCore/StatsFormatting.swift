import Foundation

/// Pure, testable formatting/data-shaping helpers for the Stats window
/// (Phase 3 / SPEC §1.6, §5 Phase 3). No IOKit, no SwiftUI/Charts — just
/// math and array manipulation so this is unit-testable without a UI.
public enum StatsFormatting {
    /// Battery health percent: `maxCapacity / designCapacity * 100`, rounded
    /// to 1 decimal place (SPEC §1.6: "AppleRawMaxCapacity vs
    /// DesignCapacity"). `designCapacity <= 0` returns `0` rather than
    /// dividing by zero (defensive; shouldn't happen with real battery data).
    public static func healthPercent(maxCapacity: Int, designCapacity: Int) -> Double {
        guard designCapacity > 0 else { return 0 }
        let ratio = Double(maxCapacity) / Double(designCapacity) * 100
        return (ratio * 10).rounded() / 10
    }

    /// Signed wattage display: `amperage (mA) * voltage (mV) / 1e6` (SPEC
    /// §5 Phase 3: "watts = Amperage×Voltage/1e6"), formatted to 1 decimal
    /// place with an explicit `+`/`-` sign, e.g. `"+15.8 W"` / `"-10.9 W"`.
    /// Amperage's sign (positive = charging, negative = discharging, per
    /// SPEC §4) carries through to the sign of the result.
    public static func watts(amperageMA: Int, voltageMV: Int) -> String {
        let watts = Double(amperageMA) * Double(voltageMV) / 1_000_000
        let sign = watts < 0 ? "-" : "+"
        let magnitude = abs(watts)
        return String(format: "%@%.1f W", sign, magnitude)
    }

    /// Evenly downsamples `samples` to at most `n` elements, always keeping
    /// the first and last elements. Returns `samples` unchanged when
    /// `samples.count <= n`. Used to cap Swift Charts data to ~200 points
    /// for a 24 h telemetry window (SPEC §5 Phase 3).
    public static func downsample<T>(_ samples: [T], to n: Int) -> [T] {
        guard samples.count > n else { return samples }
        guard n > 1 else {
            return samples.isEmpty ? [] : [samples[0]]
        }
        var result: [T] = []
        result.reserveCapacity(n)
        let lastIndex = samples.count - 1
        for i in 0..<n {
            // Evenly spaced indices across [0, lastIndex], first stays 0,
            // last stays lastIndex.
            let index = Int((Double(i) * Double(lastIndex) / Double(n - 1)).rounded())
            result.append(samples[index])
        }
        return result
    }
}
