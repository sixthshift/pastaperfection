import SwiftUI
import AmpereCore

/// Maps live daemon state to the coarse glyph state `StatusFormatting`
/// understands. Kept here (not in `AmpereCore`) because it's UI-facing
/// judgment about which glyph a given combination of flags should show;
/// `StatusFormatting.glyph(for:)` itself stays a pure lookup.
func glyphState(for payload: GetStatePayload) -> StatusFormatting.GlyphState {
    if !payload.externalConnected {
        return .dischargingUnplugged
    }
    if payload.adapterDisabled {
        return .adapterOffDischarging
    }
    if payload.chargingPaused {
        return .pausedAtLimit
    }
    if payload.isCharging {
        return .charging
    }
    // Plugged in, not paused, not charging (e.g. sitting at 100%).
    return .dischargingUnplugged
}

/// One-line human summary of the current state for the popover body.
func statusLine(for payload: GetStatePayload) -> String {
    if !payload.externalConnected {
        return "On battery"
    }
    if payload.adapterDisabled {
        return "Discharging (adapter off)"
    }
    if payload.chargingPaused {
        return "Paused"
    }
    if payload.isCharging {
        return "Charging"
    }
    return "Connected, not charging"
}

/// The menu bar label — always visible, shows percent + SF Symbol glyph.
/// Rendered as the `MenuBarExtra` label, so it must stay small.
struct MenuBarLabel: View {
    @ObservedObject var model: DaemonClientModel

    var body: some View {
        switch model.viewState {
        case .daemonUnavailable:
            Image(systemName: StatusFormatting.glyph(for: .daemonUnavailable))
        case .state(let payload):
            HStack(spacing: 4) {
                Image(systemName: StatusFormatting.glyph(for: glyphState(for: payload)))
                Text(StatusFormatting.label(percent: payload.percent))
            }
        }
    }
}

/// The popover content (`.menuBarExtraStyle(.window)`): a state summary
/// (percent, charging/paused/discharging line, limit) when the daemon is
/// reachable, `InstallPromptView` when it isn't, plus `ControlsView`
/// (limit slider / sailing toggle / action buttons / off toggle — SPEC §5
/// Phase 2). `ControlsView` always renders (even while the daemon is
/// unreachable, with its controls disabled) so the popover layout doesn't
/// jump if the daemon appears/disappears mid-session. A "Launch at login"
/// toggle appears when the login item API is available (bundled app only).
struct MenuBarView: View {
    @ObservedObject var model: DaemonClientModel
    @State private var launchAtLoginEnabled = LoginItem.status == .enabled

    /// The last known `get-state` payload, or `nil` while the daemon is
    /// unreachable — handed to `ControlsView` so its controls can render
    /// disabled instead of disappearing.
    private var currentPayload: GetStatePayload? {
        if case let .state(payload) = model.viewState {
            return payload
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.viewState {
            case .daemonUnavailable:
                InstallPromptView()
            case .state(let payload):
                HStack(spacing: 6) {
                    Image(systemName: StatusFormatting.glyph(for: glyphState(for: payload)))
                    Text(StatusFormatting.label(percent: payload.percent))
                        .font(.title2)
                        .bold()
                }
                Text(statusLine(for: payload))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Limit: \(StatusFormatting.label(percent: payload.limit))")
                    .font(.subheadline)
            }

            Divider()

            ControlsView(model: model, payload: currentPayload)

            if LoginItem.isAvailable {
                Divider()
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        LoginItem.setEnabled(newValue)
                    }
            }
        }
        .padding()
        .frame(minWidth: 240)
        .onAppear {
            // Immediate refresh on popover open, in addition to the 5 s
            // timer cadence already running in `model`.
            model.refresh()
            // Reflect the true SMAppService status in case it changed
            // outside this view (e.g. via System Settings > Login Items).
            launchAtLoginEnabled = LoginItem.status == .enabled
        }
    }
}
