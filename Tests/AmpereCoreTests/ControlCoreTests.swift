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

    // MODIFIED (SPEC §3.3 amended 2026-07-06): previously asserted that
    // externalConnected == false always cancels the discharge one-shot. But
    // this state has the adapter asserted off by us (`.disableAdapter` in
    // lastCommands) — exactly the self-induced case the amendment says must
    // NOT be treated as an unplug. Renamed/rewritten below as
    // `selfInducedUnplugDuringDischargeKeepsDischarging` (percent raised
    // above the limit so the outcome unambiguously reflects "still
    // discharging", not "reached the limit").
    @Test func selfInducedUnplugDuringDischargeKeepsDischarging() {
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.allowCharging, .disableAdapter])
        let (commands, next) = decide(
            Self.battery(percent: 85, externalConnected: false), Self.config(), state, now: Self.fixedNow
        )

        // Adapter is already recorded disabled, so no new command is needed
        // — the point is that the one-shot survives and keeps driving.
        #expect(commands.isEmpty)
        #expect(next.oneShotMode == .discharging)
        #expect(next.isAdapterDisabled == true)
    }

    @Test func genuineUnplugDuringDischargeCancelsOneShot() {
        // Contrast: adapter NOT asserted off (still enabled) — a real
        // unplug, unchanged from pre-amendment behavior.
        let state = ControlState(oneShotMode: .discharging, lastCommands: [.allowCharging, .enableAdapter])
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

    // MARK: - Calibration (SPEC §3.3, §5 Phase 4)

    @Test func calibrationHappyPathDischargeChargeHoldDone() {
        // Calibration starts already at the tail end of a limit-mode
        // inhibit (a realistic trigger: the battery was capped at the
        // limit when the user kicked off calibration), so the
        // discharge → charge transition later has a real inhibit → allow
        // flip to emit.
        let start = ControlState(
            lastCommands: [.inhibitCharging, .enableAdapter],
            calibration: CalibrationState(phase: .discharge, phaseEnteredAt: Self.fixedNow)
        )

        // Still discharging at 60%: adapter goes off; nothing to say about
        // charging yet since it's already recorded inhibited.
        let (dischargeCommands, afterDischarge) = decide(
            Self.battery(percent: 60), Self.config(), start, now: Self.fixedNow
        )
        #expect(dischargeCommands == [.disableAdapter])
        #expect(afterDischarge.calibration?.phase == .discharge)
        #expect(afterDischarge.isAdapterDisabled == true)

        // Hits the 15% floor: transitions to charge and flips the adapter
        // back on plus allows charging, in the same call.
        let chargeStart = Self.fixedNow.addingTimeInterval(60)
        let (chargeEnterCommands, afterChargeEnter) = decide(
            Self.battery(percent: 15), Self.config(), afterDischarge, now: chargeStart
        )
        #expect(Set(chargeEnterCommands) == Set([.enableAdapter, .allowCharging]))
        #expect(afterChargeEnter.calibration?.phase == .charge)
        #expect(afterChargeEnter.isAdapterDisabled == false)
        #expect(afterChargeEnter.isChargingInhibited == false)

        // Reaches 100%: transitions to hold, stamping holdStartedAt.
        let holdStart = chargeStart.addingTimeInterval(60)
        let (_, afterHoldEnter) = decide(
            Self.battery(percent: 100), Self.config(), afterChargeEnter, now: holdStart
        )
        #expect(afterHoldEnter.calibration?.phase == .hold)
        #expect(afterHoldEnter.calibration?.holdStartedAt == holdStart)

        // Contrast: 59 minutes into hold, still holding — calibration
        // persists and charging stays allowed.
        let (stillHoldingCommands, stillHolding) = decide(
            Self.battery(percent: 100), Self.config(), afterHoldEnter,
            now: holdStart.addingTimeInterval(59 * 60)
        )
        #expect(stillHoldingCommands.isEmpty)
        #expect(stillHolding.calibration?.phase == .hold)

        // 61 minutes into hold: calibration completes and limit rules
        // resume on this same call (percent 100 is well above the default
        // limit 80, so it inhibits again).
        let (doneCommands, done) = decide(
            Self.battery(percent: 100), Self.config(), afterHoldEnter,
            now: holdStart.addingTimeInterval(61 * 60)
        )
        #expect(done.calibration == nil)
        #expect(doneCommands == [.inhibitCharging])
        #expect(done.isChargingInhibited == true)
    }

    @Test func calibrationFloorAt14MovesOnToChargeNeverDischargingDeeper() {
        let state = ControlState(
            lastCommands: [.allowCharging, .disableAdapter],
            calibration: CalibrationState(phase: .discharge, phaseEnteredAt: Self.fixedNow)
        )
        let (_, next) = decide(Self.battery(percent: 14), Self.config(), state, now: Self.fixedNow)

        #expect(next.calibration?.phase == .charge)
    }

    @Test func calibrationHeatDuringChargePhaseInhibitsWithoutAbortingPhase() {
        let state = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(phase: .charge, phaseEnteredAt: Self.fixedNow)
        )
        let heatConfig = Self.config(heatProtectionEnabled: true, heatThresholdC: 35.0)
        let (commands, next) = decide(
            Self.battery(percent: 50, temperatureC: 36.0), heatConfig, state, now: Self.fixedNow
        )

        #expect(commands == [.inhibitCharging])
        #expect(next.calibration?.phase == .charge)
        #expect(next.isChargingInhibited == true)
    }

    @Test func calibrationNoHeatDuringChargePhaseAllowsCharging() {
        // Contrast with the 36°C case above: 30°C is well under the
        // threshold, so charging is allowed and the phase is unaffected.
        let state = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(phase: .charge, phaseEnteredAt: Self.fixedNow)
        )
        let heatConfig = Self.config(heatProtectionEnabled: true, heatThresholdC: 35.0)
        let (commands, next) = decide(
            Self.battery(percent: 50, temperatureC: 30.0), heatConfig, state, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.calibration?.phase == .charge)
        #expect(next.isChargingInhibited == false)
    }

    @Test func abortDuringDischargeRestoresAdapterAndLimitMode() {
        let calibrating = ControlState(
            lastCommands: [.inhibitCharging, .disableAdapter],
            calibration: CalibrationState(phase: .discharge, phaseEnteredAt: Self.fixedNow)
        )
        let aborted = calibrating.abortingCalibration()
        #expect(aborted.calibration == nil)

        let (commands, next) = decide(Self.battery(percent: 60), Self.config(), aborted, now: Self.fixedNow)

        #expect(commands.contains(.enableAdapter))
        #expect(next.calibration == nil)
        #expect(next.isAdapterDisabled == false)
        #expect(next.oneShotMode == .none)
    }

    @Test func abortDuringChargeRestoresAdapterAndLimitMode() {
        let calibrating = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(phase: .charge, phaseEnteredAt: Self.fixedNow)
        )
        let aborted = calibrating.abortingCalibration()
        #expect(aborted.calibration == nil)

        // Adapter is already enabled from the charge phase; abort still
        // lands correctly in limit mode with no adapter drift.
        let (_, next) = decide(Self.battery(percent: 70), Self.config(), aborted, now: Self.fixedNow)

        #expect(next.calibration == nil)
        #expect(next.isAdapterDisabled == false)
        #expect(next.oneShotMode == .none)
    }

    @Test func abortDuringHoldRestoresAdapterAndLimitMode() {
        let calibrating = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(
                phase: .hold, phaseEnteredAt: Self.fixedNow, holdStartedAt: Self.fixedNow
            )
        )
        let aborted = calibrating.abortingCalibration()
        #expect(aborted.calibration == nil)

        let (commands, next) = decide(Self.battery(percent: 100), Self.config(), aborted, now: Self.fixedNow)

        // Above the default limit (80) and adapter already enabled: limit
        // mode reasserts inhibitCharging, and no adapter command is needed.
        #expect(commands == [.inhibitCharging])
        #expect(next.calibration == nil)
        #expect(next.isAdapterDisabled == false)
        #expect(next.oneShotMode == .none)
    }

    // MODIFIED (SPEC §3.3 amended 2026-07-06): previously asserted that
    // externalConnected == false during calibration's discharge phase
    // always aborts calibration and re-enables the adapter. But this state
    // has the adapter asserted off by us (`.disableAdapter` in
    // lastCommands) — the self-induced case the amendment protects.
    // Renamed/rewritten below as
    // `selfInducedUnplugDuringCalibrationDischargeSurvives`; the genuine
    // unplug counterpart (adapter not asserted off) is a new test,
    // `genuineUnplugDuringCalibrationDischargeAborts`, matching the
    // unmodified pre-amendment behavior.
    @Test func selfInducedUnplugDuringCalibrationDischargeSurvives() {
        let calibrating = ControlState(
            lastCommands: [.inhibitCharging, .disableAdapter],
            calibration: CalibrationState(phase: .discharge, phaseEnteredAt: Self.fixedNow)
        )
        let (commands, next) = decide(
            Self.battery(percent: 60, externalConnected: false), Self.config(), calibrating, now: Self.fixedNow
        )

        // Adapter already recorded disabled and charging already recorded
        // inhibited — nothing new to emit, but calibration keeps driving
        // the discharge phase rather than aborting.
        #expect(commands.isEmpty)
        #expect(next.calibration?.phase == .discharge)
        #expect(next.isAdapterDisabled == true)
    }

    @Test func genuineUnplugDuringCalibrationDischargeAborts() {
        // Contrast: adapter NOT asserted off (still enabled) — a real
        // unplug, unchanged from pre-amendment behavior.
        let calibrating = ControlState(
            lastCommands: [.inhibitCharging, .enableAdapter],
            calibration: CalibrationState(phase: .discharge, phaseEnteredAt: Self.fixedNow)
        )
        let (commands, next) = decide(
            Self.battery(percent: 60, externalConnected: false), Self.config(), calibrating, now: Self.fixedNow
        )

        #expect(commands.isEmpty)
        #expect(next.calibration == nil)
        #expect(next.isAdapterDisabled == false)
    }

    // MARK: - Settle window (SPEC §3.3, amended 2026-07-06)

    @Test func settleWindowAt5SecondsAfterEnableAdapterSuppressesUnplug() {
        // enableAdapter was just emitted (adapterEnabledAt == fixedNow);
        // 5 s later externalConnected reports false — still within the 10 s
        // settle window, so calibration must not abort.
        let state = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(phase: .charge, phaseEnteredAt: Self.fixedNow),
            adapterEnabledAt: Self.fixedNow
        )
        let (commands, next) = decide(
            Self.battery(percent: 50, externalConnected: false),
            Self.config(),
            state,
            now: Self.fixedNow.addingTimeInterval(5)
        )

        #expect(commands.isEmpty)
        #expect(next.calibration?.phase == .charge)
    }

    @Test func settleWindowAt15SecondsAfterEnableAdapterTreatsPersistingDisconnectAsGenuineUnplug() {
        // Contrast: 15 s later — past the 10 s settle window — the same
        // persisting disconnect is now a genuine unplug, so calibration
        // aborts.
        let state = ControlState(
            lastCommands: [.allowCharging, .enableAdapter],
            calibration: CalibrationState(phase: .charge, phaseEnteredAt: Self.fixedNow),
            adapterEnabledAt: Self.fixedNow
        )
        let (commands, next) = decide(
            Self.battery(percent: 50, externalConnected: false),
            Self.config(),
            state,
            now: Self.fixedNow.addingTimeInterval(15)
        )

        #expect(commands.isEmpty)
        #expect(next.calibration == nil)
    }
}
