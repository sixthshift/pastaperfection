import SwiftUI
import Charts
import AppKit
import AmpereCore

/// The number of hours of telemetry the Stats window requests from
/// `get-stats` (SPEC §5 Phase 3: "24 h charts").
private let statsWindowHours = 24
/// Chart data is downsampled to at most this many points (ticket T015).
private let statsChartMaxPoints = 200

/// Presents `StatsView` in a plain `NSWindow` rather than a SwiftUI `Window`
/// scene, so opening the Stats window doesn't require adding a second scene
/// to `AmpereApp` (which is out of scope for this ticket's file contract).
/// Lazily creates one `NSWindow` + `NSHostingController` pair on first
/// `show(model:)` and retains it for the app's lifetime; subsequent calls
/// just bring the existing window to front instead of leaking a new one.
@MainActor
enum StatsWindowPresenter {
    private static var window: NSWindow?

    static func show(model: DaemonClientModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: StatsView(model: model))
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Stats"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 440, height: 480))
        newWindow.center()
        // Keep the `NSWindow` object alive across close/reopen instead of
        // deallocating it (we hold the only strong reference via `window`),
        // so `show(model:)` can just re-front the same window/content.
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The Stats window content (SPEC §1.6, §5 Phase 3, ticket T015): battery
/// health %, cycle count, current temperature, current wattage, and two
/// 24 h Swift Charts (battery percent, temperature) sourced from
/// `get-stats` via `DaemonClientModel.getStats(hours:)`.
struct StatsView: View {
    @ObservedObject var model: DaemonClientModel
    @State private var samples: [StatsSample] = []

    private var currentPayload: GetStatePayload? {
        if case let .state(payload) = model.viewState {
            return payload
        }
        return nil
    }

    private var healthPercentText: String {
        guard let payload = currentPayload else { return "--" }
        let percent = StatsFormatting.healthPercent(
            maxCapacity: payload.health.maxCapacity,
            designCapacity: payload.health.designCapacity
        )
        return String(format: "%.1f%%", percent)
    }

    private var cycleCountText: String {
        guard let payload = currentPayload else { return "--" }
        return "\(payload.health.cycleCount)"
    }

    private var temperatureText: String {
        guard let payload = currentPayload else { return "--" }
        return String(format: "%.1f\u{00B0}C", payload.temperatureC)
    }

    /// Current wattage tile. SPEC §5 Phase 3 wants `Amperage x Voltage /
    /// 1e6` (`StatsFormatting.watts`), sourced from `get-state` or (if
    /// absent there) the most recent `get-stats` sample. Neither
    /// `GetStatePayload` nor `StatsSample` carries amperage/voltage on the
    /// wire today — extending `Protocol.swift` is out of scope for this
    /// ticket's file contract — so this degrades gracefully to "N/A" until
    /// a later ticket adds those fields to the protocol.
    private var wattsText: String { "N/A" }

    private var downsampledSamples: [StatsSample] {
        StatsFormatting.downsample(samples, to: statsChartMaxPoints)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Battery Stats")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Refresh") {
                    Task { await loadStats() }
                }
            }

            HStack(spacing: 12) {
                statTile(title: "Health", value: healthPercentText)
                statTile(title: "Cycles", value: cycleCountText)
                statTile(title: "Temp", value: temperatureText)
                statTile(title: "Power", value: wattsText)
            }

            if downsampledSamples.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No telemetry yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery percent (24 h)")
                        .font(.headline)
                    Chart(downsampledSamples, id: \.timestamp) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Percent", sample.percent)
                        )
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 140)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature (24 h)")
                        .font(.headline)
                    Chart(downsampledSamples, id: \.timestamp) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("\u{00B0}C", sample.temperatureC)
                        )
                    }
                    .frame(height: 140)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 440, minHeight: 480)
        .task {
            await loadStats()
        }
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadStats() async {
        if let fetched = await model.getStats(hours: statsWindowHours) {
            samples = fetched
        }
    }
}
