import Testing
@testable import PastaPerfectionCore

@Suite struct StatusFormattingTests {
    // MARK: - glyph(for:) distinctness across contrasting states

    @Test func chargingPausedAdapterOffAndDaemonUnavailableMapToFourDistinctGlyphs() {
        let charging = StatusFormatting.glyph(for: .charging)
        let pausedAtLimit = StatusFormatting.glyph(for: .pausedAtLimit)
        let adapterOffDischarging = StatusFormatting.glyph(for: .adapterOffDischarging)
        let daemonUnavailable = StatusFormatting.glyph(for: .daemonUnavailable)

        let glyphs = [charging, pausedAtLimit, adapterOffDischarging, daemonUnavailable]
        #expect(Set(glyphs).count == glyphs.count, "expected four pairwise-distinct SF Symbol names, got \(glyphs)")
    }

    @Test func chargingGlyphLooksLikeABolt() {
        #expect(StatusFormatting.glyph(for: .charging).contains("bolt"))
    }

    @Test func pausedAtLimitGlyphLooksLikeAPause() {
        #expect(StatusFormatting.glyph(for: .pausedAtLimit).contains("pause"))
    }

    @Test func daemonUnavailableGlyphLooksLikeAWarning() {
        #expect(StatusFormatting.glyph(for: .daemonUnavailable).contains("exclamationmark"))
    }

    @Test func allFiveGlyphStatesRemainPairwiseDistinct() {
        let allStates: [StatusFormatting.GlyphState] = [
            .charging, .pausedAtLimit, .adapterOffDischarging, .dischargingUnplugged, .daemonUnavailable,
        ]
        let glyphs = allStates.map { StatusFormatting.glyph(for: $0) }
        #expect(Set(glyphs).count == glyphs.count, "expected all glyph states to map to distinct symbols, got \(glyphs)")
    }

    // MARK: - label(percent:)

    @Test func labelFormatsPercentWithSuffix() {
        #expect(StatusFormatting.label(percent: 75) == "75%")
    }

    @Test func labelFormatsDistinctPercentsDifferently() {
        #expect(StatusFormatting.label(percent: 0) == "0%")
        #expect(StatusFormatting.label(percent: 100) == "100%")
        #expect(StatusFormatting.label(percent: 0) != StatusFormatting.label(percent: 100))
    }
}
