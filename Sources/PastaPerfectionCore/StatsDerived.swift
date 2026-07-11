import Foundation

/// Pure, derived-logic helpers for the Stats dashboard (SPEC §9.5): a
/// time-to-limit estimate and a merged charge/hold/discharge session log.
/// No IOKit, no file I/O, no timers — everything here is math over an
/// injected `[StatsSample]` array so it's fully unit-testable.
public enum StatsDerived {
    /// Rate window: only samples within this many seconds of `now` qualify.
    private static let rateWindowSeconds: TimeInterval = 15 * 60
    /// At most this many (newest-first) qualifying samples feed the rate.
    private static let rateWindowCount = 10
    /// |mean rate| below this (mA) is treated as noise → `nil` estimate.
    private static let minRateMA = 50.0
    /// A gap larger than this between adjacent samples closes the current
    /// session run even if the classification is unchanged.
    private static let closeRunGapSeconds: TimeInterval = 5 * 60
    /// Runs shorter than this are dropped from the session log.
    private static let minRunDurationSeconds: TimeInterval = 5 * 60

    // MARK: - Time-to-limit

    /// A projected time (in minutes) until the battery reaches
    /// `targetPercent`, derived from the recent charge/discharge rate
    /// (SPEC §9.5).
    public struct TimeEstimate: Codable, Equatable, Sendable {
        public var minutes: Int
        public var targetPercent: Int

        public init(minutes: Int, targetPercent: Int) {
            self.minutes = minutes
            self.targetPercent = targetPercent
        }
    }

    /// Time-to-limit estimate (SPEC §9.5). Parameters are passed
    /// individually — deliberately decoupled from `GetStatePayload` — so
    /// this stays a pure, standalone function.
    ///
    /// - Rate = arithmetic mean of `amperageMA` over the newest ≤ 10
    ///   samples whose timestamp is within 15 minutes of `now`. Fewer than
    ///   1 qualifying sample, or `|mean| < 50` mA, → `nil`.
    /// - Charging (`rate > 0`): `targetPercent = limit`, but `100` when
    ///   `mode == "topping-up"` or (`mode == "calibrating"` and
    ///   `calibrationPhase == "charge"`).
    /// - Discharging (`rate < 0`): `targetPercent = limit - 5`; `limit -
    ///   sailingOffset` when `sailingEnabled`; `20` when
    ///   `mode == "discharging"`; `15` when `mode == "calibrating"` and
    ///   `calibrationPhase == "discharge"`.
    /// - `minutes` is derived from the percent gap to `targetPercent` in
    ///   the direction of travel — charging requires `targetPercent >
    ///   percent`, discharging requires `targetPercent < percent`; already
    ///   at/past the target → `nil`.
    public static func timeEstimate(
        samples: [StatsSample],
        percent: Int,
        limit: Int,
        mode: String,
        calibrationPhase: String?,
        sailingEnabled: Bool,
        sailingOffset: Int,
        maxCapacityMAh: Int,
        now: Date
    ) -> TimeEstimate? {
        let qualifying = samples.filter {
            abs($0.timestamp.timeIntervalSince(now)) <= rateWindowSeconds
        }
        let newest = qualifying
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(rateWindowCount)
        guard !newest.isEmpty else { return nil }

        let rate = Double(newest.map(\.amperageMA).reduce(0, +)) / Double(newest.count)
        guard abs(rate) >= minRateMA else { return nil }

        let targetPercent: Int
        if rate > 0 {
            if mode == "topping-up" || (mode == "calibrating" && calibrationPhase == "charge") {
                targetPercent = 100
            } else {
                targetPercent = limit
            }
        } else {
            if mode == "calibrating" && calibrationPhase == "discharge" {
                targetPercent = 15
            } else if mode == "discharging" {
                targetPercent = 20
            } else if sailingEnabled {
                targetPercent = limit - sailingOffset
            } else {
                targetPercent = limit - 5
            }
        }

        let diff = targetPercent - percent
        if rate > 0 {
            guard diff > 0 else { return nil }
        } else {
            guard diff < 0 else { return nil }
        }

        let minutesDouble = (Double(abs(diff)) / 100 * Double(maxCapacityMAh)) / abs(rate) * 60
        let minutes = Int(minutesDouble.rounded())
        return TimeEstimate(minutes: minutes, targetPercent: targetPercent)
    }

    // MARK: - Session log

    /// Classification of a merged run of samples for the charge session
    /// log (SPEC §9.5).
    public enum SessionKind: String, Codable, Equatable, Sendable {
        case charging, holding, discharging, idle
    }

    /// One merged run of consecutive same-kind samples (SPEC §9.5).
    public struct ChargeSession: Codable, Equatable, Sendable {
        public var kind: SessionKind
        public var start: Date
        public var end: Date
        public var fromPercent: Int
        public var toPercent: Int

        public init(kind: SessionKind, start: Date, end: Date, fromPercent: Int, toPercent: Int) {
            self.kind = kind
            self.start = start
            self.end = end
            self.fromPercent = fromPercent
            self.toPercent = toPercent
        }
    }

    /// Per-sample classification, precedence order (SPEC §9.5): `isCharging`
    /// → `.charging`; else `chargingPaused` → `.holding`; else `amperageMA
    /// <= -50` → `.discharging`; else `.idle`.
    private static func classify(_ sample: StatsSample) -> SessionKind {
        if sample.isCharging {
            return .charging
        } else if sample.chargingPaused {
            return .holding
        } else if sample.amperageMA <= -50 {
            return .discharging
        } else {
            return .idle
        }
    }

    /// Derives the charge/hold/discharge session log from raw samples
    /// (SPEC §9.5): classifies each sample, merges consecutive same-kind
    /// samples into runs, closes a run early when adjacent samples are
    /// more than 5 minutes apart (sleep, daemon down), and drops runs
    /// shorter than 5 minutes. Output is chronological (oldest run first);
    /// `samples` need not be pre-sorted.
    public static func sessions(from samples: [StatsSample]) -> [ChargeSession] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }

        var result: [ChargeSession] = []

        var runKind = classify(sorted[0])
        var runStart = sorted[0].timestamp
        var runEnd = sorted[0].timestamp
        var runFromPercent = sorted[0].percent
        var runToPercent = sorted[0].percent

        func closeRun() {
            if runEnd.timeIntervalSince(runStart) >= minRunDurationSeconds {
                result.append(ChargeSession(
                    kind: runKind,
                    start: runStart,
                    end: runEnd,
                    fromPercent: runFromPercent,
                    toPercent: runToPercent
                ))
            }
        }

        for sample in sorted.dropFirst() {
            let kind = classify(sample)
            let gap = sample.timestamp.timeIntervalSince(runEnd)
            if kind == runKind && gap <= closeRunGapSeconds {
                runEnd = sample.timestamp
                runToPercent = sample.percent
            } else {
                closeRun()
                runKind = kind
                runStart = sample.timestamp
                runEnd = sample.timestamp
                runFromPercent = sample.percent
                runToPercent = sample.percent
            }
        }
        closeRun()

        return result
    }
}
