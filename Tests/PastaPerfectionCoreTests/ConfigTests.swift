import Testing
import Foundation
@testable import PastaPerfectionCore

@Suite struct ConfigTests {
    @Test func decodingEmptyObjectYieldsAllDefaults() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)

        #expect(config.limitPercent == 80)
        #expect(config.sailingEnabled == false)
        #expect(config.sailingOffset == 5)
        #expect(config.heatProtectionEnabled == true)
        #expect(config.heatThresholdC == 35.0)
        #expect(config.calibrationScheduleEnabled == false)
        #expect(config.calibrationDayOfMonth == 1)
        #expect(config.mode == "limit")
    }

    @Test func decodingPartialObjectOverridesOnlyGivenField() throws {
        let json = Data(#"{"limitPercent": 60}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)

        #expect(config.limitPercent == 60)
        // Contrast with the all-defaults case: everything else still default.
        #expect(config.sailingEnabled == false)
        #expect(config.sailingOffset == 5)
        #expect(config.heatProtectionEnabled == true)
        #expect(config.heatThresholdC == 35.0)
        #expect(config.calibrationScheduleEnabled == false)
        #expect(config.calibrationDayOfMonth == 1)
        #expect(config.mode == "limit")
    }

    @Test func settingLimitClampsToFiftyToOneHundred() {
        #expect(Config.settingLimit(101) == 100)
        #expect(Config.settingLimit(10) == 50)
        #expect(Config.settingLimit(75) == 75)
        #expect(Config.settingLimit(50) == 50)
        #expect(Config.settingLimit(100) == 100)
    }

    @Test func saveThenLoadRoundTripsAllFields() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastaperfection-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        let original = Config(
            limitPercent: 70,
            sailingEnabled: true,
            sailingOffset: 8,
            heatProtectionEnabled: false,
            heatThresholdC: 38.5,
            calibrationScheduleEnabled: true,
            calibrationDayOfMonth: 15,
            mode: "off"
        )

        try original.save(to: url)
        let loaded = try Config.load(from: url)

        #expect(loaded == original)
    }

    @Test func loadDecodesOldPartialFileOnDiskWithDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastaperfection-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        try Data(#"{"mode": "off"}"#.utf8).write(to: url)

        let loaded = try Config.load(from: url)
        #expect(loaded.mode == "off")
        #expect(loaded.limitPercent == 80)
        #expect(loaded.heatThresholdC == 35.0)
    }
}
