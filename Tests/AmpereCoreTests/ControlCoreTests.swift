import Testing
import Foundation
@testable import AmpereCore

/// Contrast-table tests for the pure control core `decide(...)` (SPEC §3.3).
/// Unless a case says otherwise: limit 80, sailing off, heat protection
/// off (or a temperature far below threshold), so unrelated axes never
/// interfere with the case being tested.
@Suite struct ControlCoreTests {
    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    static func battery(
        percent: Int,
        isCharging: Bool = true,
        externalConnected: Bool = true,
        temperatureC: Double = 25.0
    ) -> BatteryState {
        BatteryState(
            percent: percent,
            isCharging: isCharging,
            externalConnected: externalConnected,
            temperatureC: temperatureC
        )
    }

    static func config(
        limitPercent: Int = 80,
        sailingEnabled: Bool = false,
        sailingOffset: Int = 5,
        heatProtectionEnabled: Bool = false,
        heatThresholdC: Double = 35.0,
        mode: String = "limit"
    ) -> Config {
        Config(
            limitPercent: limitPercent,
            sailingEnabled: sailingEnabled,
            sailingOffset: sailingOffset,
            heatProtectionEnabled: heatProtectionEnabled,
            heatThresholdC: heatThresholdC,
            mode: mode
        )
    }

    // MARK: - Limit mode hysteresis

    @Test func percent79ChargingNoPriorInhibitEmitsNoInhibitCommand() {
        let state = ControlState() // default: not inhibited, adapter enabled
        let (commands, next) = decide(Self.battery(percent: 79), Self.config(), state, now: Self.fixedNow)

        #expect(commands.isEmpty)
        #expect(next.isChargingInhibited == false)
    }

    @Test func percent80EmitsInhibitCharging() {
        let state = ControlState()
        let (commands, next) = decide(Self.battery(percent: 80), Self.config(), state, now: Self.fixedNow)

        #expect(commands == [.inhibitCharging])
        #expect(next.isChargingInhibited == true)
    }

    @Test func percent78AfterInhibitKeepsInhibitedNoAllowCommand() {
        // Between the resume floor (75) and the limit (80): keep previous.
        let state = ControlState(lastCommands: [.inhibitCharging, .enableAdapter])
        let (commands, next) = decide(Self.battery(percent: 78), Self.config(), state, now: Self.fixedNow)

        #expect(commands.isEmpty)
        #expect(next.isChargingInhibited == true)
    }

    @Test func percent75AfterInhibitEmitsAllowCharging() {
        let state = ControlState(lastCommands: [.inhibitCharging, .enableAdapter])
        let (commands, next) = decide(Self.battery(percent: 75), Self.config(), state, now: Self.fixedNow)

        #expect(commands == [.allowCharging])
        #expect(next.isChargingInhibited == false)
    }

    @Test func sailingOnOffset10AllowsOnlyAtOrBelow70() {
        let sailingConfig = Self.config(sailingEnabled: true, sailingOffset: 10)
        let inhibited = ControlState(lastCommands: [.inhibitCharging, .enableAdapter])

        // Contrast: 71 keeps inhibited, 70 releases.
        let (commandsAt71, nextAt71) = decide(Self.battery(percent: 71), sailingConfig, inhibited, now: Self.fixedNow)
        #expect(commandsAt71.isEmpty)
        #expect(nextAt71.isChargingInhibited == true)

        let (commandsAt70, nextAt70) = decide(Self.battery(percent: 70), sailingConfig, inhibited, now: Self.fixedNow)
        #expect(commandsAt70 == [.allowCharging])
        #expect(nextAt70.isChargingInhibited == false)
    }

    // MARK: - Heat protection (overrides everything)

    @Test func temperature36AboveThreshold35ForcesInhibitEvenWellBelowLimit() {
        // percent 50 is nowhere near limit 80 — only heat explains the inhibit.
        let state = ControlState()
        let heatConfig = Self.config(heatProtectionEnabled: true, heatThresholdC: 35.0)
        let (commands, next) = decide(
            Self.battery(percent: 50, temperatureC: 36.0), heatConfig, state, now: Self.fixedNow
        )

        #expect(commands == [.inhibitCharging])
        #expect(next.heatInhibited == true)
        #expect(next.isChargingInhibited == true)
    }

    @Test func temperature33AtReleaseBoundAllowsAgain() {
        // Starting from a heat-inhibited state, dropping to threshold - 2
        // releases heat and falls through to limit-mode logic (percent 50
        // is well under the limit-mode resume floor, so it allows).
        let heatInhibitedState = ControlState(
            heatInhibited: true,
            lastCommands: [.inhibitCharging, .enableAdapter]
        )
        let heatConfig = Self.config(heatProtectionEnabled: true, heatThresholdC: 35.0)
        let (commands, next) = decide(
            Self.battery(percent: 50, temperatureC: 33.0), heatConfig, heatInhibitedState, now: Self.fixedNow
        )

        #expect(commands == [.allowCharging])
        #expect(next.heatInhibited == false)
        #expect(next.isChargingInhibited == false)
    }

    @Test func temperature34WhileHeatInhibitedKeepsInhibited() {
        // Contrast with the 33 case above: 34 is between the release bound
        // (33) and the threshold (35), so heat protection keeps inhibiting.
        let heatInhibitedState = ControlState(
            heatInhibited: true,
            lastCommands: [.inhibitCharging, .enableAdapter]
        )
        let heatConfig = Self.config(heatProtectionEnabled: true, heatThresholdC: 35.0)
        let (commands, next) = decide(
            Self.battery(percent: 50, temperatureC: 34.0), heatConfig, heatInhibitedState, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.heatInhibited == true)
        #expect(next.isChargingInhibited == true)
    }

    // MARK: - Discharge-to-limit one-shot

    @Test func discharging81AboveLimit80EmitsDisableAdapter() {
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.allowCharging, .enableAdapter])
        let (commands, next) = decide(Self.battery(percent: 81), Self.config(), state, now: Self.fixedNow)

        #expect(commands == [.disableAdapter])
        #expect(next.oneShotMode == .discharging)
        #expect(next.isAdapterDisabled == true)
    }

    @Test func discharging80AtLimitEmitsEnableAdapterAndRevertsToLimitMode() {
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.allowCharging, .disableAdapter])
        let (commands, next) = decide(Self.battery(percent: 80), Self.config(), state, now: Self.fixedNow)

        #expect(commands == [.enableAdapter])
        #expect(next.oneShotMode == .none)
        #expect(next.isAdapterDisabled == false)
    }

    @Test func discharging19BreachesHardFloorRestoringFullyAndRevertingToLimitMode() {
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.inhibitCharging, .disableAdapter])
        let (commands, next) = decide(Self.battery(percent: 19), Self.config(), state, now: Self.fixedNow)

        #expect(commands == [.enableAdapter, .allowCharging])
        #expect(next.oneShotMode == .none)
        #expect(next.isAdapterDisabled == false)
        #expect(next.isChargingInhibited == false)
    }

    // MARK: - Top-up one-shot

    @Test func toppingUp99NotChargingRevertsToLimitMode() {
        let state = ControlState(oneShotMode: .toppingUp, lastCommands: [.allowCharging, .enableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 99, isCharging: false), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.oneShotMode == .none)
    }

    @Test func toppingUp99StillChargingKeepsAllowing() {
        // Starting from an inhibited hardware state (as if entered top-up
        // right after being capped at the limit): still below completion,
        // so it (re-)emits allowCharging and keeps topping up.
        let state = ControlState(oneShotMode: .toppingUp, lastCommands: [.inhibitCharging, .enableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 99, isCharging: true), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands == [.allowCharging])
        #expect(next.oneShotMode == .toppingUp)
        #expect(next.isChargingInhibited == false)
    }

    @Test func toppingUp100EmitsNoCommandAndRevertsToLimitMode() {
        let state = ControlState(oneShotMode: .toppingUp, lastCommands: [.allowCharging, .enableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 100, isCharging: true), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.oneShotMode == .none)
    }

    // MARK: - No external power

    @Test func externalConnectedFalseEmitsNoHardwareCommands() {
        let state = ControlState(lastCommands: [.allowCharging, .enableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 50, externalConnected: false), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.lastCommands == state.lastCommands)
    }

    @Test func externalConnectedFalseCancelsDischargingOneShot() {
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.allowCharging, .disableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 50, externalConnected: false), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.oneShotMode == .none)
    }

    @Test func externalConnectedFalseDoesNotCancelToppingUpOneShot() {
        let state = ControlState(oneShotMode: .toppingUp, lastCommands: [.allowCharging, .enableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 50, externalConnected: false), Self.config(), state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.oneShotMode == .toppingUp)
    }

    // MARK: - mode == "off"

    @Test func modeOffRestoresChargingAndAdapterOnceThenGoesQuiet() {
        let inhibitedState = ControlState(
            oneShotMode: .discharging,
            lastCommands: [.inhibitCharging, .disableAdapter]
        )
        let offConfig = Self.config(mode: "off")

        let (firstCommands, next) = decide(Self.battery(percent: 50), offConfig, inhibitedState, now: Self.fixedNow)
        #expect(firstCommands == [.allowCharging, .enableAdapter])
        #expect(next.oneShotMode == .none)
        #expect(next.isChargingInhibited == false)
        #expect(next.isAdapterDisabled == false)

        // Second tick: already restored, so nothing further to emit.
        let (secondCommands, _) = decide(Self.battery(percent: 50), offConfig, next, now: Self.fixedNow)
        #expect(secondCommands.isEmpty)
    }

    // MARK: - Idempotence

    @Test func repeatedCallsAtSamePercentEmitNoDuplicateCommands() {
        let state = ControlState()
        let (_, afterFirst) = decide(Self.battery(percent: 80), Self.config(), state, now: Self.fixedNow)
        let (commands, _) = decide(Self.battery(percent: 80), Self.config(), afterFirst, now: Self.fixedNow)

        #expect(commands.isEmpty)
    }
}
