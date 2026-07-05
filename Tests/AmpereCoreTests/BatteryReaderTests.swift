import Testing
@testable import AmpereCore

@Suite struct BatteryReaderTests {
    private static let chargingFixture: [String: Any] = [
        "CurrentCapacity": 62,
        "IsCharging": true,
        "ExternalConnected": true,
        "Temperature": 3011,
        "CycleCount": 412,
        "AppleRawMaxCapacity": 4382,
        "DesignCapacity": 5088,
        "Amperage": 1250,
        "Voltage": 12600
    ]

    private static let dischargingFixture: [String: Any] = [
        "CurrentCapacity": 62,
        "IsCharging": false,
        "ExternalConnected": false,
        "Temperature": 3011,
        "CycleCount": 412,
        "AppleRawMaxCapacity": 4382,
        "DesignCapacity": 5088,
        "Amperage": -890,
        "Voltage": 12600
    ]

    @Test func chargingFixtureParsesExpectedFields() {
        let reading = BatteryReader.parse(Self.chargingFixture)

        #expect(reading.percent == 62)
        #expect(reading.isCharging == true)
        #expect(reading.externalConnected == true)
        #expect(reading.temperatureC == 30.11)
        #expect(reading.cycleCount == 412)
        #expect(reading.appleRawMaxCapacity == 4382)
        #expect(reading.designCapacity == 5088)
        #expect(reading.amperageMA == 1250)
        #expect(reading.voltageMV == 12600)
        #expect(reading.complete == true)

        // Watts computable: 1250 mA * 12600 mV / 1e6 = 15.75 W.
        #expect(abs(reading.watts - 15.75) < 0.0001)

        // The frozen SPEC §3.3 projection matches.
        let state = reading.state
        #expect(state.percent == 62)
        #expect(state.isCharging == true)
        #expect(state.externalConnected == true)
        #expect(state.temperatureC == 30.11)
    }

    @Test func dischargingFixtureDiffersOnlyInChargingAndCurrentFields() {
        let charging = BatteryReader.parse(Self.chargingFixture)
        let discharging = BatteryReader.parse(Self.dischargingFixture)

        // Fields that must differ.
        #expect(discharging.isCharging == false)
        #expect(discharging.externalConnected == false)
        #expect(discharging.amperageMA == -890)

        #expect(charging.isCharging != discharging.isCharging)
        #expect(charging.externalConnected != discharging.externalConnected)
        #expect(charging.amperageMA != discharging.amperageMA)

        // Everything else must be unchanged between the two fixtures.
        #expect(charging.percent == discharging.percent)
        #expect(charging.temperatureC == discharging.temperatureC)
        #expect(charging.cycleCount == discharging.cycleCount)
        #expect(charging.appleRawMaxCapacity == discharging.appleRawMaxCapacity)
        #expect(charging.designCapacity == discharging.designCapacity)
        #expect(charging.voltageMV == discharging.voltageMV)
        #expect(discharging.complete == true)

        // Negative amperage yields negative wattage.
        #expect(discharging.watts < 0)
    }

    @Test func emptyDictionaryIsIncompleteButNeverCrashes() {
        let reading = BatteryReader.parse([:])

        #expect(reading.complete == false)
        #expect(reading.percent == 0)
        #expect(reading.isCharging == false)
        #expect(reading.externalConnected == false)
        #expect(reading.temperatureC == 0.0)
        #expect(reading.cycleCount == 0)
        #expect(reading.appleRawMaxCapacity == 0)
        #expect(reading.designCapacity == 0)
        #expect(reading.amperageMA == 0)
        #expect(reading.voltageMV == 0)
    }

    @Test func partiallyMissingKeysAreIncompleteWithDefaultsForMissingOnly() {
        let partial: [String: Any] = [
            "CurrentCapacity": 50,
            "IsCharging": true
        ]
        let reading = BatteryReader.parse(partial)

        #expect(reading.complete == false)
        #expect(reading.percent == 50)
        #expect(reading.isCharging == true)
        #expect(reading.externalConnected == false)
        #expect(reading.temperatureC == 0.0)
    }
}
