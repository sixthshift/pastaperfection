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

    /// `get-stats` merge (SPEC §9.3): combines archived (coarse, 15-min
    /// bucketed) history with hot (raw, 60 s) telemetry into the wire shape,
    /// then caps the result to ≤ 2,000 samples via `downsample`.
    ///
    /// `hoursBack == 0` means "all history" — no window filtering at all
    /// (SPEC §9.3: `"hours":0` now means "all history"). A positive
    /// `hoursBack` filters both `archive` and `hot` to samples/buckets no
    /// older than `hoursBack` hours ago before merging.
    ///
    /// Only archive buckets **strictly older** than the oldest (filtered)
    /// hot sample are included — this avoids double-counting time already
    /// covered by raw hot samples. When there are no hot samples at all (in
    /// the window), every (filtered) archive bucket is eligible.
    ///
    /// Archive buckets map to `StatsSample` per SPEC §9.3: `percent =
    /// round(percentAvg)`, `isCharging = chargingFraction >= 0.5`,
    /// `chargingPaused = pausedFraction >= 0.5`, averages copied (rounded
    /// for the `Int` fields). Hot samples map via `StatsSample.init(_:)`
    /// (T027). The combined result is sorted chronologically before capping.
    public static func mergedStats(
        archive: [ArchiveSample],
        hot: [TelemetrySample],
        hoursBack: Double
    ) -> [StatsSample] {
        let cutoff: Date? = hoursBack > 0 ? Date().addingTimeInterval(-hoursBack * 3600) : nil

        let filteredHot = cutoff.map { c in hot.filter { $0.ts >= c } } ?? hot
        let filteredArchive = cutoff.map { c in archive.filter { $0.ts >= c } } ?? archive

        let oldestHotTs = filteredHot.map(\.ts).min()
        let eligibleArchive: [ArchiveSample]
        if let oldestHotTs {
            eligibleArchive = filteredArchive.filter { $0.ts < oldestHotTs }
        } else {
            eligibleArchive = filteredArchive
        }

        let archiveMapped = eligibleArchive.map { bucket -> StatsSample in
            StatsSample(
                timestamp: bucket.ts,
                percent: Int(bucket.percentAvg.rounded()),
                isCharging: bucket.chargingFraction >= 0.5,
                temperatureC: bucket.temperatureCAvg,
                amperageMA: Int(bucket.amperageMAAvg.rounded()),
                voltageMV: Int(bucket.voltageMVAvg.rounded()),
                chargingPaused: bucket.pausedFraction >= 0.5
            )
        }
        let hotMapped = filteredHot.map(StatsSample.init)

        let merged = (archiveMapped + hotMapped).sorted { $0.timestamp < $1.timestamp }
        return downsample(merged, to: 2000)
    }
}
