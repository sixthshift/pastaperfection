import Testing
import Foundation
@testable import PastaPerfectionCore

@Suite struct StatsDerivedTests {
    // Fixed "now" so timestamp-relative fixtures are deterministic.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func sample(
        minutesAgo: Double,
        percent: Int = 60,
        isCharging: Bool = false,
        amperageMA: Int = 0,
        chargingPaused: Bool = false
    ) -> StatsSample {
        StatsSample(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            percent: percent,
            isCharging: isCharging,
            temperatureC: 30.0,
            amperageMA: amperageMA,
            voltageMV: 12_000,
            chargingPaused: chargingPaused
        )
    }

    // MARK: - timeEstimate: contrast (amperage only differs)

    @Test func timeEstimateContrastingAmperageProducesDifferentMinutes() {
        let samples1000 = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        let samples2000 = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 2000)
        }

        let estimate1000 = StatsDerived.timeEstimate(
            samples: samples1000, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        let estimate2000 = StatsDerived.timeEstimate(
            samples: samples2000, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )

        // (20/100 * 5199) / 1000 * 60 = 62.388 -> 62
        #expect(estimate1000 == StatsDerived.TimeEstimate(minutes: 62, targetPercent: 80))
        // (20/100 * 5199) / 2000 * 60 = 31.194 -> 31
        #expect(estimate2000 == StatsDerived.TimeEstimate(minutes: 31, targetPercent: 80))
        #expect(estimate1000?.minutes != estimate2000?.minutes)
    }

    // MARK: - timeEstimate: rate window exclusion

    @Test func timeEstimateExcludesSamplesOlderThanFifteenMinutes() {
        // Recent, qualifying samples: 1000 mA -> expect the 1000-mA answer.
        let recent = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        // Old samples well outside the 15-minute window, with wildly
        // different amperage that would change the answer if wrongly
        // included in the mean.
        let old = [
            Self.sample(minutesAgo: 20, isCharging: true, amperageMA: 9000),
            Self.sample(minutesAgo: 25, isCharging: true, amperageMA: 9000),
        ]

        let estimate = StatsDerived.timeEstimate(
            samples: old + recent, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )

        #expect(estimate == StatsDerived.TimeEstimate(minutes: 62, targetPercent: 80))
    }

    @Test func timeEstimateFewerThanOneQualifyingSampleReturnsNil() {
        let allOld = [
            Self.sample(minutesAgo: 20, isCharging: true, amperageMA: 1000),
            Self.sample(minutesAgo: 30, isCharging: true, amperageMA: 1000),
        ]
        let estimate = StatsDerived.timeEstimate(
            samples: allOld, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate == nil)
    }

    @Test func timeEstimateEmptySamplesReturnsNil() {
        let estimate = StatsDerived.timeEstimate(
            samples: [], percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate == nil)
    }

    @Test func timeEstimateBelowFiftyMilliampMagnitudeReturnsNil() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 10)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate == nil)
    }

    @Test func timeEstimatePercentAlreadyAtLimitWhileChargingReturnsNil() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 80, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate == nil)
    }

    // MARK: - timeEstimate: target percent selection

    @Test func timeEstimateDischargingWithSailingUsesLimitMinusOffset() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: false, amperageMA: -1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 80, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: true, sailingOffset: 8,
            maxCapacityMAh: 5199, now: Self.now
        )
        // target = 80 - 8 = 72; (8/100 * 5199) / 1000 * 60 = 24.9552 -> 25
        #expect(estimate == StatsDerived.TimeEstimate(minutes: 25, targetPercent: 72))
    }

    @Test func timeEstimateDischargingWithoutSailingUsesLimitMinusFive() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: false, amperageMA: -1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 80, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate?.targetPercent == 75)
    }

    @Test func timeEstimateDischargeToLimitModeTargetsTwenty() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: false, amperageMA: -1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 50, limit: 80, mode: "discharging",
            calibrationPhase: nil, sailingEnabled: true, sailingOffset: 8,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate?.targetPercent == 20)
    }

    @Test func timeEstimateCalibratingDischargePhaseTargetsFifteen() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: false, amperageMA: -1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 50, limit: 80, mode: "calibrating",
            calibrationPhase: "discharge", sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate?.targetPercent == 15)
    }

    @Test func timeEstimateToppingUpWhileChargingTargetsOneHundred() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 90, limit: 80, mode: "topping-up",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate?.targetPercent == 100)
    }

    @Test func timeEstimateCalibratingChargePhaseTargetsOneHundred() {
        let samples = (1...3).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 90, limit: 80, mode: "calibrating",
            calibrationPhase: "charge", sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate?.targetPercent == 100)
    }

    @Test func timeEstimateUsesOnlyNewestTenQualifyingSamples() {
        // 12 qualifying samples (within 15 min), all 1000 mA, plus one
        // outlier that is older than the newest 10 but still within the
        // 15-minute window. If the outlier were wrongly included the mean
        // (and thus minutes) would differ.
        var samples = (1...12).map {
            Self.sample(minutesAgo: Double($0), isCharging: true, amperageMA: 1000)
        }
        samples.append(Self.sample(minutesAgo: 11.5, isCharging: true, amperageMA: 9000))

        let estimate = StatsDerived.timeEstimate(
            samples: samples, percent: 60, limit: 80, mode: "off",
            calibrationPhase: nil, sailingEnabled: false, sailingOffset: 0,
            maxCapacityMAh: 5199, now: Self.now
        )
        #expect(estimate == StatsDerived.TimeEstimate(minutes: 62, targetPercent: 80))
    }

    // MARK: - sessions

    private static func session(
        secondsFromEpoch: TimeInterval,
        percent: Int,
        isCharging: Bool = false,
        amperageMA: Int = 0,
        chargingPaused: Bool = false
    ) -> StatsSample {
        StatsSample(
            timestamp: Date(timeIntervalSince1970: secondsFromEpoch),
            percent: percent,
            isCharging: isCharging,
            temperatureC: 30.0,
            amperageMA: amperageMA,
            voltageMV: 12_000,
            chargingPaused: chargingPaused
        )
    }

    @Test func sessionsEmptyInputReturnsEmpty() {
        #expect(StatsDerived.sessions(from: []) == [])
    }

    @Test func sessionsGapOverFiveMinutesSplitsRunIntoTwo() {
        let base: TimeInterval = 2_000_000_000
        // Run 1: discharging, 0..360s (6 min span).
        let run1 = stride(from: 0.0, through: 360.0, by: 60.0).map {
            Self.session(secondsFromEpoch: base + $0, percent: 80, amperageMA: -200)
        }
        // Gap of 400s (> 300s) before run 2.
        // Run 2: discharging, 760..1120s (6 min span).
        let run2 = stride(from: 760.0, through: 1120.0, by: 60.0).map {
            Self.session(secondsFromEpoch: base + $0, percent: 70, amperageMA: -200)
        }

        let result = StatsDerived.sessions(from: run1 + run2)

        #expect(result.count == 2)
        #expect(result[0].kind == .discharging)
        #expect(result[0].start == Date(timeIntervalSince1970: base))
        #expect(result[0].end == Date(timeIntervalSince1970: base + 360))
        #expect(result[1].kind == .discharging)
        #expect(result[1].start == Date(timeIntervalSince1970: base + 760))
        #expect(result[1].end == Date(timeIntervalSince1970: base + 1120))
    }

    @Test func sessionsGapUnderFiveMinutesMergesIntoSingleRun() {
        let base: TimeInterval = 2_000_000_000
        // Same shape as the split test, but the gap between the two halves
        // is only 240s (< 300s), so this must merge into ONE run.
        let part1 = stride(from: 0.0, through: 360.0, by: 60.0).map {
            Self.session(secondsFromEpoch: base + $0, percent: 80, amperageMA: -200)
        }
        let part2 = stride(from: 600.0, through: 960.0, by: 60.0).map {
            Self.session(secondsFromEpoch: base + $0, percent: 70, amperageMA: -200)
        }

        let result = StatsDerived.sessions(from: part1 + part2)

        #expect(result.count == 1)
        #expect(result[0].start == Date(timeIntervalSince1970: base))
        #expect(result[0].end == Date(timeIntervalSince1970: base + 960))
    }

    @Test func sessionsShortRunIsDroppedWhileLongRunIsKept() {
        let base: TimeInterval = 2_000_000_000
        // Run 1: idle, 4-minute span -> dropped.
        let shortRun = [
            Self.session(secondsFromEpoch: base, percent: 50, amperageMA: 0),
            Self.session(secondsFromEpoch: base + 240, percent: 52, amperageMA: 0),
        ]
        // Gap > 5 min forces a new run even though the kind is unchanged.
        // Run 2: idle, exactly a 5-minute span (300s, at the keep boundary
        // and also within the 300s merge-gap boundary) -> kept.
        let longRun = [
            Self.session(secondsFromEpoch: base + 640, percent: 60, amperageMA: 0),
            Self.session(secondsFromEpoch: base + 940, percent: 65, amperageMA: 0),
        ]

        let result = StatsDerived.sessions(from: shortRun + longRun)

        #expect(result.count == 1)
        #expect(result[0].kind == .idle)
        #expect(result[0].fromPercent == 60)
        #expect(result[0].toPercent == 65)
        #expect(result[0].start == Date(timeIntervalSince1970: base + 640))
        #expect(result[0].end == Date(timeIntervalSince1970: base + 940))
    }

    @Test func sessionsClassificationPrecedenceAcrossAllFourKinds() {
        let base: TimeInterval = 2_000_000_000

        // Each run's two samples are exactly 300s apart: within the 300s
        // merge-gap boundary (so they merge into one run) and exactly at
        // the 300s keep-duration boundary (so the run survives).
        // Run 1: isCharging && chargingPaused both true -> charging wins.
        let chargingRun = [
            Self.session(secondsFromEpoch: base, percent: 50, isCharging: true, amperageMA: 1200, chargingPaused: true),
            Self.session(secondsFromEpoch: base + 300, percent: 56, isCharging: true, amperageMA: 1200, chargingPaused: true),
        ]
        // Run 2: chargingPaused && amperage very negative -> holding wins
        // over discharging.
        let holdingRun = [
            Self.session(secondsFromEpoch: base + 360, percent: 70, isCharging: false, amperageMA: -1000, chargingPaused: true),
            Self.session(secondsFromEpoch: base + 660, percent: 64, isCharging: false, amperageMA: -1000, chargingPaused: true),
        ]
        // Run 3: not charging, not paused, amperage <= -50 -> discharging.
        let dischargingRun = [
            Self.session(secondsFromEpoch: base + 720, percent: 80, isCharging: false, amperageMA: -200, chargingPaused: false),
            Self.session(secondsFromEpoch: base + 1020, percent: 74, isCharging: false, amperageMA: -200, chargingPaused: false),
        ]
        // Run 4: not charging, not paused, amperage above -50 -> idle.
        let idleRun = [
            Self.session(secondsFromEpoch: base + 1080, percent: 40, isCharging: false, amperageMA: -10, chargingPaused: false),
            Self.session(secondsFromEpoch: base + 1380, percent: 42, isCharging: false, amperageMA: -10, chargingPaused: false),
        ]

        let result = StatsDerived.sessions(from: chargingRun + holdingRun + dischargingRun + idleRun)

        #expect(result.count == 4)
        #expect(result[0].kind == .charging)
        #expect(result[0].fromPercent == 50)
        #expect(result[0].toPercent == 56)
        #expect(result[1].kind == .holding)
        #expect(result[1].fromPercent == 70)
        #expect(result[1].toPercent == 64)
        #expect(result[2].kind == .discharging)
        #expect(result[2].fromPercent == 80)
        #expect(result[2].toPercent == 74)
        #expect(result[3].kind == .idle)
        #expect(result[3].fromPercent == 40)
        #expect(result[3].toPercent == 42)
    }

    @Test func sessionsUnsortedInputIsProcessedChronologically() {
        let base: TimeInterval = 2_000_000_000
        let sorted = stride(from: 0.0, through: 360.0, by: 60.0).map {
            Self.session(secondsFromEpoch: base + $0, percent: 80, amperageMA: -200)
        }
        let shuffled = Array(sorted.reversed())

        let result = StatsDerived.sessions(from: shuffled)

        #expect(result.count == 1)
        #expect(result[0].start == Date(timeIntervalSince1970: base))
        #expect(result[0].end == Date(timeIntervalSince1970: base + 360))
        #expect(result[0].fromPercent == 80)
        #expect(result[0].toPercent == 80)
    }
}
