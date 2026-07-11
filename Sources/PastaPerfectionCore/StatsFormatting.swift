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

    /// Raw wattage: `amperage (mA) * voltage (mV) / 1e6` (SPEC §5 Phase 3:
    /// "watts = Amperage×Voltage/1e6"). Signed — positive while charging,
    /// negative while discharging (per SPEC §4's amperage sign convention).
    /// Used both by `watts(amperageMA:voltageMV:)`'s formatted display and
    /// directly by the dashboard's power chart (ticket T030).
    public static func wattsValue(amperageMA: Int, voltageMV: Int) -> Double {
        Double(amperageMA) * Double(voltageMV) / 1_000_000
    }

    /// Signed wattage display, formatted to 1 decimal place with an
    /// explicit `+`/`-` sign, e.g. `"+15.8 W"` / `"-10.9 W"`.
    public static func watts(amperageMA: Int, voltageMV: Int) -> String {
        let watts = wattsValue(amperageMA: amperageMA, voltageMV: voltageMV)
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
                chargingPaused: bucket.pausedFraction >= 0.5,
                maxCapacityMAh: bucket.maxCapacityMAhAvg.map { Int($0.rounded()) }
            )
        }
        let hotMapped = filteredHot.map(StatsSample.init)

        let merged = (archiveMapped + hotMapped).sorted { $0.timestamp < $1.timestamp }
        return downsample(merged, to: 2000)
    }

    // MARK: - Dashboard (T030 / SPEC §9.6)

    /// The dashboard's range picker (SPEC §9.6): 24 h / 7 d / 30 d / All,
    /// mapping to `get-stats`'s `hours` parameter (`0` meaning "all history",
    /// per §9.3).
    public enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
        case day = "24 h"
        case week = "7 d"
        case month = "30 d"
        case all = "All"

        public var id: String { rawValue }

        public var hours: Int {
            switch self {
            case .day: return 24
            case .week: return 168
            case .month: return 720
            case .all: return 0
            }
        }
    }

    /// A contiguous x-span of `chargingPaused == true` samples, used to draw
    /// paused-region shading (`RectangleMark`) behind the battery %/power
    /// `LineMark`s (SPEC §9.6).
    public struct PausedInterval: Equatable, Sendable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// Derives contiguous `chargingPaused == true` runs from `samples`
    /// (sorted by timestamp first, so callers needn't pre-sort) as x-span
    /// intervals for chart shading. A run of a single sample yields a
    /// zero-width interval (`start == end`). Empty when no sample is paused.
    public static func pausedIntervals(_ samples: [StatsSample]) -> [PausedInterval] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var result: [PausedInterval] = []
        var runStart: Date?
        var runEnd: Date?
        for sample in sorted {
            if sample.chargingPaused {
                if runStart == nil {
                    runStart = sample.timestamp
                }
                runEnd = sample.timestamp
            } else if let start = runStart, let end = runEnd {
                result.append(PausedInterval(start: start, end: end))
                runStart = nil
                runEnd = nil
            }
        }
        if let start = runStart, let end = runEnd {
            result.append(PausedInterval(start: start, end: end))
        }
        return result
    }

    /// Formats a duration like `"3 h 12 m"` (hours present) or `"48 m"`
    /// (under an hour) — shared by the session-row and time-estimate
    /// formatters below. Minutes are zero-padded to 2 digits when an hours
    /// component is present (e.g. `"1 h 05 m"`), matching SPEC §9.5's
    /// examples.
    static func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(format: "%d h %02d m", hours, minutes)
        }
        return "\(minutes) m"
    }

    /// Session-row display string for the dashboard's session list (SPEC
    /// §9.1/§9.5), e.g. `"Held at 80% — 3 h 12 m"`,
    /// `"Charged 62% → 80% — 48 m"`, `"Discharged 100% → 80% — 1 h 05 m"`.
    public static func sessionRowText(_ session: StatsDerived.ChargeSession) -> String {
        let duration = durationText(session.end.timeIntervalSince(session.start))
        switch session.kind {
        case .holding:
            return "Held at \(session.toPercent)% — \(duration)"
        case .charging:
            return "Charged \(session.fromPercent)% \u{2192} \(session.toPercent)% — \(duration)"
        case .discharging:
            return "Discharged \(session.fromPercent)% \u{2192} \(session.toPercent)% — \(duration)"
        case .idle:
            return "Idle — \(duration)"
        }
    }

    /// Time-to-limit display string (SPEC §9.5), e.g. `"≈ 1 h 40 m to 80%"`.
    public static func timeEstimateText(_ estimate: StatsDerived.TimeEstimate) -> String {
        let duration = durationText(TimeInterval(estimate.minutes * 60))
        return "\u{2248} \(duration) to \(estimate.targetPercent)%"
    }

    /// Live voltage detail row (SPEC §9.1): `"%.2f V"`.
    public static func voltageText(voltageMV: Int) -> String {
        String(format: "%.2f V", Double(voltageMV) / 1000)
    }

    /// Live amperage detail row (SPEC §9.1): signed mA, e.g. `"+1250 mA"` /
    /// `"-890 mA"`.
    public static func amperageText(amperageMA: Int) -> String {
        let sign = amperageMA < 0 ? "-" : "+"
        return "\(sign)\(abs(amperageMA)) mA"
    }

    /// Charger info row (SPEC §9.1): the adapter's descriptive name when
    /// present (e.g. `"96W USB-C Power Adapter"` — the hardware-reported
    /// name already embeds the wattage), `"96 W adapter"` synthesized from
    /// `watts` when the adapter has no name, `"No charger"` when there's no
    /// adapter at all.
    public static func chargerText(_ adapter: AdapterPayload?) -> String {
        guard let adapter else { return "No charger" }
        if let name = adapter.name {
            return name
        }
        return "\(adapter.watts) W adapter"
    }
}
