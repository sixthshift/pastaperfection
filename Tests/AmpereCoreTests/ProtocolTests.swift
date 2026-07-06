import Testing
import Foundation
@testable import AmpereCore

@Suite struct ProtocolTests {
    // MARK: - Request round trips

    @Test func getStateRoundTrips() throws {
        let line = try ProtocolCodec.encodeLine(Request.getState)
        let decoded = try ProtocolCodec.decodeRequest(from: line)
        #expect(decoded == .getState)
        #expect(line.contains(#""cmd":"get-state""#))
    }

    @Test func setLimitRoundTripsAndDistinctValuesDecodeDifferently() throws {
        let line65 = try ProtocolCodec.encodeLine(Request.setLimit(value: 65))
        let line80 = try ProtocolCodec.encodeLine(Request.setLimit(value: 80))

        let decoded65 = try ProtocolCodec.decodeRequest(from: line65)
        let decoded80 = try ProtocolCodec.decodeRequest(from: line80)

        #expect(decoded65 == .setLimit(value: 65))
        #expect(decoded80 == .setLimit(value: 80))
        #expect(decoded65 != decoded80)
    }

    @Test func setConfigRoundTripsPartialFields() throws {
        let partial = PartialConfig(limitPercent: 70, sailingEnabled: true)
        let line = try ProtocolCodec.encodeLine(Request.setConfig(config: partial))
        let decoded = try ProtocolCodec.decodeRequest(from: line)

        guard case let .setConfig(config: decodedConfig) = decoded else {
            Issue.record("expected .setConfig, got \(decoded)")
            return
        }
        #expect(decodedConfig.limitPercent == 70)
        #expect(decodedConfig.sailingEnabled == true)
        #expect(decodedConfig.sailingOffset == nil)
        #expect(decodedConfig.mode == nil)
    }

    @Test func partialConfigMergesOnlyProvidedFields() {
        let base = Config()
        let partial = PartialConfig(limitPercent: 65)
        let merged = partial.merged(onto: base)

        #expect(merged.limitPercent == 65)
        // Contrast: everything else stays at base's value, unmodified.
        #expect(merged.sailingEnabled == base.sailingEnabled)
        #expect(merged.sailingOffset == base.sailingOffset)
        #expect(merged.heatProtectionEnabled == base.heatProtectionEnabled)
        #expect(merged.heatThresholdC == base.heatThresholdC)
        #expect(merged.calibrationScheduleEnabled == base.calibrationScheduleEnabled)
        #expect(merged.calibrationDayOfMonth == base.calibrationDayOfMonth)
        #expect(merged.mode == base.mode)
    }

    @Test func getConfigRoundTrips() throws {
        let line = try ProtocolCodec.encodeLine(Request.getConfig)
        let decoded = try ProtocolCodec.decodeRequest(from: line)
        #expect(decoded == .getConfig)
    }

    @Test func actionRoundTripsForEveryName() throws {
        let names: [ActionName] = [.dischargeToLimit, .topUp, .calibrateStart, .calibrateAbort]
        for name in names {
            let line = try ProtocolCodec.encodeLine(Request.action(name: name))
            let decoded = try ProtocolCodec.decodeRequest(from: line)
            #expect(decoded == .action(name: name))
        }
        // Contrast: distinct names decode to distinct requests.
        let dischargeLine = try ProtocolCodec.encodeLine(Request.action(name: .dischargeToLimit))
        let topUpLine = try ProtocolCodec.encodeLine(Request.action(name: .topUp))
        #expect(dischargeLine != topUpLine)
    }

    @Test func getStatsRoundTripsAndDistinctHoursDecodeDifferently() throws {
        let line24 = try ProtocolCodec.encodeLine(Request.getStats(hours: 24))
        let line48 = try ProtocolCodec.encodeLine(Request.getStats(hours: 48))

        let decoded24 = try ProtocolCodec.decodeRequest(from: line24)
        let decoded48 = try ProtocolCodec.decodeRequest(from: line48)

        #expect(decoded24 == .getStats(hours: 24))
        #expect(decoded48 == .getStats(hours: 48))
        #expect(decoded24 != decoded48)
    }

    // MARK: - Unknown command

    @Test func unknownCmdDecodesToUnknownCase() throws {
        let decoded = try ProtocolCodec.decodeRequest(from: #"{"cmd":"bogus"}"#)
        #expect(decoded == .unknown(cmd: "bogus"))
    }

    @Test func unknownCmdProducesErrorResponseWithOkFalseAndNonEmptyError() throws {
        let decoded = try ProtocolCodec.decodeRequest(from: #"{"cmd":"bogus"}"#)
        let response = decoded.unknownCommandResponse
        #expect(response != nil)
        #expect(response?.ok == false)
        #expect(response?.data == nil)
        #expect(!(response?.error?.isEmpty ?? true))

        let line = try ProtocolCodec.encodeLine(response!)
        #expect(line.contains(#""ok":false"#))
        #expect(line.contains("error"))
    }

    @Test func actionWithUnrecognizedNameDecodesToUnknown() throws {
        let decoded = try ProtocolCodec.decodeRequest(from: #"{"cmd":"action","name":"levitate"}"#)
        #expect(decoded == .unknown(cmd: "action"))
        #expect(decoded.unknownCommandResponse?.ok == false)
    }

    @Test func knownCommandsHaveNoUnknownResponse() throws {
        #expect(Request.getState.unknownCommandResponse == nil)
        #expect(Request.setLimit(value: 80).unknownCommandResponse == nil)
        #expect(Request.getConfig.unknownCommandResponse == nil)
    }

    // MARK: - get-state payload

    private func makePayload(pauseReason: PauseReason?, calibration: CalibrationPayload? = nil) -> GetStatePayload {
        GetStatePayload(
            percent: 75,
            isCharging: false,
            externalConnected: true,
            chargingPaused: pauseReason != nil,
            pauseReason: pauseReason,
            adapterDisabled: false,
            mode: "limit",
            limit: 80,
            temperatureC: 30.1,
            health: HealthPayload(maxCapacity: 4382, designCapacity: 5088, cycleCount: 412),
            calibration: calibration
        )
    }

    @Test func getStatePauseReasonHeatVsLimitEncodeToDifferentJSON() throws {
        let heatPayload = makePayload(pauseReason: .heat)
        let limitPayload = makePayload(pauseReason: .limit)

        let heatResponse = GetStateResponse.success(heatPayload)
        let limitResponse = GetStateResponse.success(limitPayload)

        let heatLine = try ProtocolCodec.encodeLine(heatResponse)
        let limitLine = try ProtocolCodec.encodeLine(limitResponse)

        #expect(heatLine != limitLine)
        #expect(heatLine.contains(#""pauseReason":"heat""#))
        #expect(limitLine.contains(#""pauseReason":"limit""#))
    }

    // MODIFIED (SPEC §3.1 amended: `get-state` must emit an explicit
    // `"calibration":null` rather than omitting the key). Previously
    // asserted `!line.contains("calibration")`; that now contradicts the
    // spec, so this asserts the explicit-null literal instead. Round-trip
    // decode behavior (calibration decodes back to `nil`) is unchanged.
    @Test func getStatePayloadRoundTripsWithNilPauseReasonAndCalibration() throws {
        let payload = makePayload(pauseReason: nil)
        let response = GetStateResponse.success(payload)
        let line = try ProtocolCodec.encodeLine(response)

        #expect(!line.contains("pauseReason"))
        #expect(line.contains(#""calibration":null"#))

        let decoded = try ProtocolCodec.decode(GetStateResponse.self, from: line)
        #expect(decoded.ok == true)
        #expect(decoded.data?.pauseReason == nil)
        #expect(decoded.data?.calibration == nil)
        #expect(decoded.data?.writeVerified == true)
    }

    @Test func getStatePayloadRoundTripsWithCalibration() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let calibration = CalibrationPayload(phase: "discharge", startedAt: startedAt)
        let payload = makePayload(pauseReason: nil, calibration: calibration)
        let response = GetStateResponse.success(payload)

        let line = try ProtocolCodec.encodeLine(response)
        let decoded = try ProtocolCodec.decode(GetStateResponse.self, from: line)

        #expect(decoded.data?.calibration?.phase == "discharge")
        #expect(decoded.data?.calibration?.startedAt == startedAt)
    }

    /// Contrast test (this ticket): nil calibration must encode the literal
    /// explicit-null substring; a present calibration must encode as an
    /// object, never the bare omission either encode could otherwise take.
    @Test func calibrationEncodesExplicitNullWhenNilAndAsObjectWhenPresent() throws {
        let nilPayload = makePayload(pauseReason: nil, calibration: nil)
        let nilLine = try ProtocolCodec.encodeLine(GetStateResponse.success(nilPayload))
        #expect(nilLine.contains(#""calibration":null"#))

        let calibration = CalibrationPayload(
            phase: "discharge", startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let presentPayload = makePayload(pauseReason: nil, calibration: calibration)
        let presentLine = try ProtocolCodec.encodeLine(GetStateResponse.success(presentPayload))
        #expect(presentLine.contains(#""calibration":{"#))
        #expect(!presentLine.contains(#""calibration":null"#))
    }

    @Test func writeVerifiedDefaultsTrueWhenAbsentFromJSON() throws {
        let json = """
        {"percent":75,"isCharging":false,"externalConnected":true,"chargingPaused":false,
        "adapterDisabled":false,"mode":"limit","limit":80,"temperatureC":30.1,
        "health":{"maxCapacity":4382,"designCapacity":5088,"cycleCount":412},"calibration":null}
        """
        let payload = try ProtocolCodec.decode(GetStatePayload.self, from: json)
        #expect(payload.writeVerified == true)
    }

    @Test func writeVerifiedFalseSurvivesRoundTrip() throws {
        var payload = makePayload(pauseReason: nil)
        payload.writeVerified = false
        let line = try ProtocolCodec.encodeLine(payload)
        #expect(line.contains(#""writeVerified":false"#))

        let decoded = try ProtocolCodec.decode(GetStatePayload.self, from: line)
        #expect(decoded.writeVerified == false)
    }

    // MARK: - get-config response reuses Config

    @Test func getConfigResponseRoundTripsUsingConfigType() throws {
        let config = Config(limitPercent: 70, mode: "off")
        let response = GetConfigResponse.success(config)
        let line = try ProtocolCodec.encodeLine(response)
        let decoded = try ProtocolCodec.decode(GetConfigResponse.self, from: line)

        #expect(decoded.data == config)
    }

    // MARK: - get-stats payload

    @Test func statsPayloadRoundTrips() throws {
        let sample1 = StatsSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            percent: 60, isCharging: true, temperatureC: 28.5,
            amperageMA: 1200, voltageMV: 12500
        )
        let sample2 = StatsSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_060),
            percent: 61, isCharging: true, temperatureC: 28.6,
            amperageMA: -800, voltageMV: 12600
        )
        let payload = StatsPayload(samples: [sample1, sample2])
        let response = GetStatsResponse.success(payload)

        let line = try ProtocolCodec.encodeLine(response)
        let decoded = try ProtocolCodec.decode(GetStatsResponse.self, from: line)

        #expect(decoded.data?.samples.count == 2)
        #expect(decoded.data?.samples.first?.percent == 60)
        #expect(decoded.data?.samples.last?.percent == 61)
        #expect(decoded.data?.samples.first?.amperageMA == 1200)
        #expect(decoded.data?.samples.first?.voltageMV == 12500)
        #expect(decoded.data?.samples.last?.amperageMA == -800)
        #expect(decoded.data?.samples.last?.voltageMV == 12600)
    }

    /// Old telemetry/wire payloads recorded before `amperageMA`/`voltageMV`
    /// were added to `StatsSample` must still decode, defaulting the new
    /// fields to `0` (matching `Config`'s defaulting style).
    @Test func statsSampleDecodesWithoutAmperageVoltageKeys() throws {
        let json = """
        {"timestamp":"2023-11-14T22:13:20Z","percent":60,"isCharging":true,"temperatureC":28.5}
        """
        let decoded = try ProtocolCodec.decode(StatsSample.self, from: json)

        #expect(decoded.percent == 60)
        #expect(decoded.amperageMA == 0)
        #expect(decoded.voltageMV == 0)
    }

    // MARK: - Response envelope shape

    @Test func successResponseOmitsErrorKey() throws {
        let response = AckResponse.success(EmptyPayload())
        let line = try ProtocolCodec.encodeLine(response)
        #expect(line.contains(#""ok":true"#))
        #expect(!line.contains("error"))
    }

    @Test func failureResponseOmitsDataKey() throws {
        let response = AckResponse.failure("adapter unavailable")
        let line = try ProtocolCodec.encodeLine(response)
        #expect(line.contains(#""ok":false"#))
        #expect(line.contains("adapter unavailable"))
        #expect(!line.contains("\"data\""))
    }
}
