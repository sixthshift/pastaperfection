import SwiftUI
import AmpereCore

/// The popover's controls section (SPEC §3.1, §5 Phase 2/3, tickets T012, T016):
/// limit slider, sailing toggle + offset stepper, heat protection toggle +
/// threshold stepper, discharge/top-up one-shot buttons, an off/limit mode
/// toggle, and two conditional advisory rows (heat pause,
/// write-verification canary).
///
/// Every mutation here goes through a `DaemonClientModel` method
/// (`setLimit`/`setConfig`/`sendAction`) — this view never constructs
/// `SocketClient` itself. `payload` is `nil` while the daemon is
/// unreachable; in that case every control renders disabled rather than the
/// section disappearing, since the daemon can come back at any moment while
/// the popover stays open.
struct ControlsView: View {
    @ObservedObject var model: DaemonClientModel
    let payload: GetStatePayload?

    /// Local slider position. Kept separate from `payload.limit` so dragging
    /// updates the live "%" label immediately without sending a `set-limit`
    /// on every tick — only `onEditingChanged(false)` (release) sends.
    @State private var sliderValue: Double = Double(Config.defaultLimitPercent)
    @State private var isEditingLimit = false

    private var isDaemonAvailable: Bool { payload != nil }

    private var currentMode: String { payload?.mode ?? Config.defaultMode }
    private var isOff: Bool { currentMode == "off" }
    private var dischargeActive: Bool { currentMode == "discharging" }
    private var topUpActive: Bool { currentMode == "topping-up" }

    private var sailingEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.config?.sailingEnabled ?? Config.defaultSailingEnabled },
            set: { newValue in model.setConfig(PartialConfig(sailingEnabled: newValue)) }
        )
    }

    private var sailingOffsetBinding: Binding<Int> {
        Binding(
            get: { model.config?.sailingOffset ?? Config.defaultSailingOffset },
            set: { newValue in model.setConfig(PartialConfig(sailingOffset: newValue)) }
        )
    }

    private var heatProtectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.config?.heatProtectionEnabled ?? Config.defaultHeatProtectionEnabled },
            set: { newValue in model.setConfig(PartialConfig(heatProtectionEnabled: newValue)) }
        )
    }

    /// `Stepper` needs an `Int` for whole-degree steps; `heatThresholdC` is a
    /// `Double` on the wire (SPEC §3.2) so the binding round-trips through
    /// `Int` for display/editing and sends back a `Double`.
    private var heatThresholdBinding: Binding<Int> {
        Binding(
            get: {
                Int((model.config?.heatThresholdC ?? Config.defaultHeatThresholdC).rounded())
            },
            set: { newValue in
                model.setConfig(PartialConfig(heatThresholdC: Double(newValue)))
            }
        )
    }

    /// `true` maps to config `mode == "off"`, `false` to `mode == "limit"` —
    /// the one-shot runtime modes (`discharging`/`topping-up`/`calibrating`)
    /// are never written here, only read via `isOff`.
    private var offBinding: Binding<Bool> {
        Binding(
            get: { isOff },
            set: { newValue in
                model.setConfig(PartialConfig(mode: newValue ? "off" : "limit"))
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            limitSection
            sailingSection
            heatProtectionSection
            Divider()
            actionButtons
            Divider()
            offSection

            if let payload, payload.pauseReason == .heat {
                heatRow(temperatureC: payload.temperatureC)
            }
            if let payload, payload.writeVerified == false {
                writeVerifiedWarningRow
            }
        }
        .onAppear {
            if let limit = payload?.limit {
                sliderValue = Double(limit)
            }
        }
        .onChange(of: payload?.limit) { _, newLimit in
            guard !isEditingLimit, let newLimit else { return }
            sliderValue = Double(newLimit)
        }
    }

    // MARK: - Limit slider

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Charge limit")
                Spacer()
                Text("\(Int(sliderValue))%")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $sliderValue,
                in: 50...100,
                step: 5,
                onEditingChanged: { editing in
                    isEditingLimit = editing
                    if !editing {
                        // Send only on release (SPEC §5 Phase 2), never per-tick.
                        model.setLimit(Int(sliderValue))
                    }
                }
            )
            .disabled(!isDaemonAvailable)
        }
    }

    // MARK: - Sailing

    private var sailingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Sailing mode", isOn: sailingEnabledBinding)
                .disabled(!isDaemonAvailable)
            if sailingEnabledBinding.wrappedValue {
                Stepper(
                    "Resume offset: \(sailingOffsetBinding.wrappedValue)%",
                    value: sailingOffsetBinding,
                    in: 5...20
                )
                .disabled(!isDaemonAvailable)
            }
        }
    }

    // MARK: - Heat protection

    private var heatProtectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Heat protection", isOn: heatProtectionEnabledBinding)
                .disabled(!isDaemonAvailable)
            if heatProtectionEnabledBinding.wrappedValue {
                Stepper(
                    "Pause threshold: \(heatThresholdBinding.wrappedValue) \u{00B0}C",
                    value: heatThresholdBinding,
                    in: 30...45
                )
                .disabled(!isDaemonAvailable)
            }
        }
    }

    // MARK: - One-shot actions

    private var actionButtons: some View {
        HStack {
            Button("Discharge to limit") {
                model.sendAction(.dischargeToLimit)
            }
            .disabled(!isDaemonAvailable || dischargeActive)

            Button("Top up to 100%") {
                model.sendAction(.topUp)
            }
            .disabled(!isDaemonAvailable || topUpActive)
        }
    }

    // MARK: - Off toggle

    private var offSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Charging off (no limit control)", isOn: offBinding)
                .disabled(!isDaemonAvailable)
            Text("Off lets the battery charge normally to 100% — Ampere won't intervene.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advisory rows

    private func heatRow(temperatureC: Double) -> some View {
        Label(
            "Charging paused: battery hot (\(String(format: "%.1f", temperatureC))\u{00B0}C)",
            systemImage: "thermometer.sun.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
    }

    private var writeVerifiedWarningRow: some View {
        Text("\u{26A0}\u{FE0E} Charge control may be broken by a macOS update")
            .font(.caption)
            .foregroundStyle(.red)
    }
}
