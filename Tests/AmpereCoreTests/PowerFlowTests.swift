import Testing
@testable import AmpereCore

@Suite struct PowerFlowTests {
    @Test func adapterChargingWhenExternalAndPositiveAmperage() {
        let pf = PowerFlowCore.compute(
            externalConnected: true, isCharging: true, chargingPaused: false,
            amperageMA: 2000, voltageMV: 12_600
        )
        #expect(pf.direction == .adapterCharging)
        #expect(abs(pf.watts - 25.2) < 0.0001)
    }

    @Test func adapterHoldingWhenExternalNonPositiveAmperageAndPaused() {
        let pf = PowerFlowCore.compute(
            externalConnected: true, isCharging: false, chargingPaused: true,
            amperageMA: 0, voltageMV: 12_600
        )
        #expect(pf.direction == .adapterHolding)
    }

    @Test func adapterOnlyWhenExternalNonPositiveAmperageNotPaused() {
        let pf = PowerFlowCore.compute(
            externalConnected: true, isCharging: false, chargingPaused: false,
            amperageMA: 0, voltageMV: 12_600
        )
        #expect(pf.direction == .adapterOnly)
    }

    @Test func batteryWhenExternalNotConnected() {
        let pf = PowerFlowCore.compute(
            externalConnected: false, isCharging: false, chargingPaused: false,
            amperageMA: -1500, voltageMV: 12_000
        )
        #expect(pf.direction == .battery)
        #expect(abs(pf.watts - 18.0) < 0.0001)
    }

    @Test func fourInputsProduceFourDifferentDirections() {
        let charging = PowerFlowCore.compute(
            externalConnected: true, isCharging: true, chargingPaused: false,
            amperageMA: 2000, voltageMV: 12_600
        )
        let holding = PowerFlowCore.compute(
            externalConnected: true, isCharging: false, chargingPaused: true,
            amperageMA: 0, voltageMV: 12_600
        )
        let adapterOnly = PowerFlowCore.compute(
            externalConnected: true, isCharging: false, chargingPaused: false,
            amperageMA: 0, voltageMV: 12_600
        )
        let battery = PowerFlowCore.compute(
            externalConnected: false, isCharging: false, chargingPaused: false,
            amperageMA: -1500, voltageMV: 12_000
        )

        let directions: Set<PowerFlowDirection> = [
            charging.direction, holding.direction, adapterOnly.direction, battery.direction,
        ]
        #expect(directions.count == 4)
    }

    @Test func pausedPluggedAndUnpluggedYieldDifferentDirections() {
        let pausedPlugged = PowerFlowCore.compute(
            externalConnected: true, isCharging: false, chargingPaused: true,
            amperageMA: -50, voltageMV: 12_000
        )
        let unplugged = PowerFlowCore.compute(
            externalConnected: false, isCharging: false, chargingPaused: false,
            amperageMA: -50, voltageMV: 12_000
        )
        #expect(pausedPlugged.direction == .adapterHolding)
        #expect(unplugged.direction == .battery)
        #expect(pausedPlugged.direction != unplugged.direction)
    }
}
