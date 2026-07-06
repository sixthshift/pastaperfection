import Testing
import Foundation
@testable import AmpereCore

@Suite struct StatsFormattingTests {
    // MARK: - healthPercent

    @Test func healthPercentComputesMAhRatioRoundedToOneDecimal() {
        #expect(StatsFormatting.healthPercent(maxCapacity: 4382, designCapacity: 5088) == 86.1)
    }

    @Test func healthPercentAtFullCapacityIsOneHundred() {
        #expect(StatsFormatting.healthPercent(maxCapacity: 5088, designCapacity: 5088) == 100.0)
    }

    // MARK: - watts

    @Test func wattsPositiveAmperageFormatsWithPlusSign() {
        #expect(StatsFormatting.watts(amperageMA: 1250, voltageMV: 12600) == "+15.8 W")
    }

    @Test func wattsNegativeAmperageFormatsWithMinusSign() {
        #expect(StatsFormatting.watts(amperageMA: -890, voltageMV: 12200) == "-10.9 W")
    }

    @Test func wattsContrastingSignsProduceDifferentPrefixes() {
        let positive = StatsFormatting.watts(amperageMA: 1250, voltageMV: 12600)
        let negative = StatsFormatting.watts(amperageMA: -890, voltageMV: 12200)
        #expect(positive.hasPrefix("+"))
        #expect(negative.hasPrefix("-"))
    }

    // MARK: - downsample

    @Test func downsampleOfTwoThousandToTwoHundredReturnsExactlyTwoHundred() {
        let fixtures = Array(0..<2000)
        let result = StatsFormatting.downsample(fixtures, to: 200)
        #expect(result.count == 200)
        #expect(result.first == fixtures.first)
        #expect(result.last == fixtures.last)
    }

    @Test func downsampleOfFiftyToTwoHundredReturnsAllFifty() {
        let fixtures = Array(0..<50)
        let result = StatsFormatting.downsample(fixtures, to: 200)
        #expect(result.count == 50)
        #expect(result == fixtures)
    }

    @Test func downsampleExactlyAtLimitReturnsUnchanged() {
        let fixtures = Array(0..<200)
        let result = StatsFormatting.downsample(fixtures, to: 200)
        #expect(result == fixtures)
    }

    @Test func downsampleIsMonotonicallyIncreasingIndices() {
        let fixtures = Array(0..<2000)
        let result = StatsFormatting.downsample(fixtures, to: 200)
        for i in 1..<result.count {
            #expect(result[i] > result[i - 1])
        }
    }

    // MARK: - mergedStats

    private func archiveSample(ts: Date, pausedFraction: Double = 0, chargingFraction: Double = 0) -> ArchiveSample {
        ArchiveSample(
            ts: ts,
            percentAvg: 75.0,
            percentMin: 70,
            percentMax: 80,
            temperatureCAvg: 30.0,
            amperageMAAvg: -400.0,
            voltageMVAvg: 12_000.0,
            chargingFraction: chargingFraction,
            pausedFraction: pausedFraction,
            count: 15
        )
    }

    private func hotSample(ts: Date, percent: Int = 50) -> TelemetrySample {
        TelemetrySample(
            ts: ts,
            percent: percent,
            isCharging: true,
            temperatureC: 28.0,
            amperageMA: 1000,
            voltageMV: 12_000,
            chargingPaused: false
        )
    }

    @Test func mergedStatsHoursBackZeroWithOverTwoThousandInputsCapsToTwoThousandSpanningBothEras() {
        let archiveBase = Date(timeIntervalSince1970: 1_000_000_000)
        let archive = (0..<1500).map { i in
            archiveSample(ts: archiveBase.addingTimeInterval(Double(i) * 900))
        }
        // Hot era starts well after the archive era ends.
        let hotBase = archiveBase.addingTimeInterval(Double(1500) * 900 + 3600)
        let hot = (0..<1000).map { i in
            hotSample(ts: hotBase.addingTimeInterval(Double(i) * 60))
        }

        let merged = StatsFormatting.mergedStats(archive: archive, hot: hot, hoursBack: 0)

        #expect(merged.count == 2000)
        // Chronological.
        for i in 1..<merged.count {
            #expect(merged[i].timestamp >= merged[i - 1].timestamp)
        }
        // Spans both eras: first sample from the archive era, last from hot.
        #expect(merged.first?.timestamp == archive.first?.ts)
        #expect(merged.last?.timestamp == hot.last?.ts)
    }

    @Test func mergedStatsMapsPausedFractionAboveHalfToChargingPausedTrue() {
        let archive = [archiveSample(ts: Date(timeIntervalSince1970: 0), pausedFraction: 0.6)]
        let merged = StatsFormatting.mergedStats(archive: archive, hot: [], hoursBack: 0)
        #expect(merged.count == 1)
        #expect(merged[0].chargingPaused == true)
    }

    @Test func mergedStatsMapsPausedFractionBelowHalfToChargingPausedFalse() {
        let archive = [archiveSample(ts: Date(timeIntervalSince1970: 0), pausedFraction: 0.4)]
        let merged = StatsFormatting.mergedStats(archive: archive, hot: [], hoursBack: 0)
        #expect(merged.count == 1)
        #expect(merged[0].chargingPaused == false)
    }

    @Test func mergedStatsMapsChargingFractionAboveHalfToIsChargingTrue() {
        let archive = [archiveSample(ts: Date(timeIntervalSince1970: 0), chargingFraction: 0.6)]
        let merged = StatsFormatting.mergedStats(archive: archive, hot: [], hoursBack: 0)
        #expect(merged.count == 1)
        #expect(merged[0].isCharging == true)
    }

    @Test func mergedStatsMapsChargingFractionBelowHalfToIsChargingFalse() {
        let archive = [archiveSample(ts: Date(timeIntervalSince1970: 0), chargingFraction: 0.4)]
        let merged = StatsFormatting.mergedStats(archive: archive, hot: [], hoursBack: 0)
        #expect(merged.count == 1)
        #expect(merged[0].isCharging == false)
    }

    @Test func mergedStatsExcludesArchiveBucketsNotOlderThanOldestHotSample() {
        let hotTs = Date(timeIntervalSince1970: 1_000_000)
        let hot = [hotSample(ts: hotTs)]
        // One archive bucket strictly older than the hot sample (eligible),
        // one at the same instant (should be excluded to avoid
        // double-counting time already covered by the hot sample).
        let olderArchive = archiveSample(ts: hotTs.addingTimeInterval(-3600))
        let overlappingArchive = archiveSample(ts: hotTs)
        let merged = StatsFormatting.mergedStats(archive: [olderArchive, overlappingArchive], hot: hot, hoursBack: 0)

        // Exactly 2 entries: the eligible older-archive bucket plus the one
        // hot sample — the overlapping (same-ts, not strictly older) archive
        // bucket must be dropped, not duplicated alongside the hot sample.
        #expect(merged.count == 2)
        #expect(merged.map(\.timestamp).contains(olderArchive.ts))
        #expect(merged.filter { $0.timestamp == hotTs }.count == 1)
    }

    @Test func mergedStatsPositiveHoursBackFiltersBothSourcesToWindow() {
        let now = Date()
        let recentArchive = archiveSample(ts: now.addingTimeInterval(-3600 * 2)) // 2h ago
        let staleArchive = archiveSample(ts: now.addingTimeInterval(-3600 * 100)) // way outside window
        let recentHot = hotSample(ts: now.addingTimeInterval(-60)) // 1 min ago
        let staleHot = hotSample(ts: now.addingTimeInterval(-3600 * 100))

        let merged = StatsFormatting.mergedStats(
            archive: [recentArchive, staleArchive],
            hot: [recentHot, staleHot],
            hoursBack: 24
        )

        let timestamps = merged.map(\.timestamp)
        #expect(timestamps.contains(recentArchive.ts))
        #expect(timestamps.contains(recentHot.ts))
        #expect(!timestamps.contains(staleArchive.ts))
        #expect(!timestamps.contains(staleHot.ts))
    }
}
