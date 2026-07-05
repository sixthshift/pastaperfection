import Testing
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
}
