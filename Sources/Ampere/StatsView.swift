import SwiftUI
import Charts
import AppKit
import AmpereCore

/// Chart data is downsampled to at most this many points per chart, after
/// range selection (ticket T030 / SPEC §9.6).
private let dashboardChartMaxPoints = 400
/// Live-values tick cadence (SPEC §9.6): re-fetches `get-state` for the
/// tiles/detail rows/time-to-limit line.
private let liveRefreshInterval: TimeInterval = 5.0
/// Charts/sessions tick cadence (SPEC §9.6): re-fetches `get-stats` for the
/// selected range.
private let chartsRefreshInterval: TimeInterval = 60.0
/// Low-opacity accent fill for paused-region shading (SPEC §9.6).
private let pausedShadingColor = Color.orange.opacity(0.15)

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
        // Built via the plain designated initializer (rather than
        // `NSWindow(contentViewController:)`) so the window exists before
        // `StatsView` is constructed — the view needs a reference to its
        // own hosting window (`isVisible`, for the live-refresh timers'
        // no-op-when-hidden gate, SPEC §9.6) that a `contentViewController:`
        // convenience init can't supply up front.
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Stats"
        newWindow.setContentSize(NSSize(width: 480, height: 640))
        newWindow.contentMinSize = NSSize(width: 440, height: 480)
        newWindow.center()
        // Keep the `NSWindow` object alive across close/reopen instead of
        // deallocating it (we hold the only strong reference via `window`),
        // so `show(model:)` can just re-front the same window/content.
        newWindow.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: StatsView(model: model, window: newWindow))
        newWindow.contentViewController = hosting
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The Stats window content (SPEC §9.6, ticket T030): a single scrolling
/// dashboard — header tiles, live detail rows (voltage/amperage, charger,
/// time-to-limit), a range picker, three Swift Charts (battery %,
/// temperature, power) with paused-region shading, and a session list. All
/// judgeable formatting/derivation logic lives in `AmpereCore`
/// (`StatsFormatting`, `StatsDerived`) — this view only renders.
struct StatsView: View {
    @ObservedObject var model: DaemonClientModel
    /// The hosting `NSWindow` (set once by `StatsWindowPresenter`). `weak`
    /// because the window already owns this view (via its
    /// `NSHostingController`) — a strong reference back would be a retain
    /// cycle. Used only to gate the live-refresh timers on `isVisible`.
    weak var window: NSWindow?

    /// Raw (server-downsampled-to-≤2000, not yet client-downsampled)
    /// samples for the currently selected range. Feeds the charts (via
    /// `chartSamples`), the session list, and the time-to-limit rate window.
    @State private var samples: [StatsSample] = []
    @State private var selectedRange: StatsFormatting.DashboardRange = .day
    @State private var liveTimer: Timer?
    @State private var chartsTimer: Timer?

    init(model: DaemonClientModel, window: NSWindow?) {
        self.model = model
        self.window = window
    }

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
    /// 1e6` (`StatsFormatting.watts`), computed from the most recently
    /// fetched `get-stats` sample. Shows "N/A" only when no samples have
    /// been fetched yet.
    private var wattsText: String {
        guard let latest = samples.last else { return "N/A" }
        return StatsFormatting.watts(amperageMA: latest.amperageMA, voltageMV: latest.voltageMV)
    }

    private var voltageText: String? {
        guard let latest = samples.last else { return nil }
        return StatsFormatting.voltageText(voltageMV: latest.voltageMV)
    }

    private var amperageText: String? {
        guard let latest = samples.last else { return nil }
        return StatsFormatting.amperageText(amperageMA: latest.amperageMA)
    }

    private var chargerText: String {
        StatsFormatting.chargerText(currentPayload?.adapter)
    }

    /// Time-to-limit line (SPEC §9.5/§9.6); `nil` hides the line entirely.
    /// `percent`/`limit`/`mode`/`calibrationPhase` come from the live
    /// `get-state` payload; `sailingEnabled`/`sailingOffset` from
    /// `model.config` (`get-config`, kept fresh by the model's own 5 s poll);
    /// `maxCapacityMAh` is `health.maxCapacity`.
    private var timeEstimateText: String? {
        guard let payload = currentPayload else { return nil }
        let config = model.config ?? Config()
        guard let estimate = StatsDerived.timeEstimate(
            samples: samples,
            percent: payload.percent,
            limit: payload.limit,
            mode: payload.mode,
            calibrationPhase: payload.calibration?.phase,
            sailingEnabled: config.sailingEnabled,
            sailingOffset: config.sailingOffset,
            maxCapacityMAh: payload.health.maxCapacity,
            now: Date()
        ) else {
            return nil
        }
        return StatsFormatting.timeEstimateText(estimate)
    }

    /// Chart data: `samples` capped to ≤ 400 points client-side (SPEC §9.6),
    /// on top of the server's ≤ 2,000-sample cap.
    private var chartSamples: [StatsSample] {
        StatsFormatting.downsample(samples, to: dashboardChartMaxPoints)
    }

    /// Paused-region shading spans, computed from the full-resolution
    /// `samples` (not `chartSamples`) so shading boundaries stay accurate
    /// even when the chart itself is downsampled — Swift Charts' date axis
    /// is continuous, so this doesn't need to line up with plotted points.
    private var pausedIntervals: [StatsFormatting.PausedInterval] {
        StatsFormatting.pausedIntervals(samples)
    }

    /// Session list rows (SPEC §9.1/§9.5): newest ≤ 20, newest first, idle
    /// runs omitted.
    private var displaySessions: [StatsDerived.ChargeSession] {
        let nonIdle = StatsDerived.sessions(from: samples).filter { $0.kind != .idle }
        return Array(nonIdle.reversed().prefix(20))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Battery Stats")
                        .font(.title2)
                        .bold()
                    Spacer()
                    Button("Refresh") {
                        model.refresh()
                        Task { await loadStats() }
                    }
                }

                HStack(spacing: 12) {
                    statTile(title: "Health", value: healthPercentText)
                    statTile(title: "Cycles", value: cycleCountText)
                    statTile(title: "Temp", value: temperatureText)
                    statTile(title: "Power", value: wattsText)
                }

                detailRows

                Picker("Range", selection: $selectedRange) {
                    ForEach(StatsFormatting.DashboardRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedRange) { _, _ in
                    Task { await loadStats() }
                }

                if chartSamples.isEmpty {
                    Text("No telemetry yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    charts
                }

                sessionList
            }
            .padding()
        }
        .frame(minWidth: 440, minHeight: 480)
        .task {
            await loadStats()
            startTimersIfNeeded()
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let voltageText, let amperageText {
                Text("\(voltageText)  \u{2022}  \(amperageText)")
                    .font(.callout)
            }
            Text(chargerText)
                .font(.callout)
            if let timeEstimateText {
                Text(timeEstimateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Battery percent")
                    .font(.headline)
                Chart {
                    ForEach(pausedIntervals, id: \.start) { interval in
                        RectangleMark(
                            xStart: .value("Start", interval.start),
                            xEnd: .value("End", interval.end)
                        )
                        .foregroundStyle(pausedShadingColor)
                    }
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Percent", sample.percent)
                        )
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Temperature")
                    .font(.headline)
                Chart(chartSamples, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("\u{00B0}C", sample.temperatureC)
                    )
                }
                .frame(height: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Power (W)")
                    .font(.headline)
                Chart {
                    ForEach(pausedIntervals, id: \.start) { interval in
                        RectangleMark(
                            xStart: .value("Start", interval.start),
                            xEnd: .value("End", interval.end)
                        )
                        .foregroundStyle(pausedShadingColor)
                    }
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("W", StatsFormatting.wattsValue(
                                amperageMA: sample.amperageMA, voltageMV: sample.voltageMV
                            ))
                        )
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions")
                .font(.headline)
            if displaySessions.isEmpty {
                Text("No sessions yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(displaySessions.enumerated()), id: \.offset) { _, session in
                    Text(StatsFormatting.sessionRowText(session))
                        .font(.callout)
                }
            }
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
        if let fetched = await model.getStats(hours: selectedRange.hours) {
            samples = fetched
        }
    }

    /// Starts the two live-refresh `Timer`s (SPEC §9.6), idempotently —
    /// safe to call more than once (e.g. if `.task` re-runs) since it no-ops
    /// once both timers exist. Deliberately never torn down on
    /// `onDisappear`: the hosting window is retained for the app's lifetime
    /// (`StatsWindowPresenter`), so "disappear" (window closed/hidden) isn't
    /// a real teardown — each tick instead no-ops via the `window?.isVisible`
    /// guard below.
    private func startTimersIfNeeded() {
        if liveTimer == nil {
            let timer = Timer(timeInterval: liveRefreshInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard window?.isVisible == true else { return }
                    model.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
        if chartsTimer == nil {
            let timer = Timer(timeInterval: chartsRefreshInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard window?.isVisible == true else { return }
                    await loadStats()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            chartsTimer = timer
        }
    }
}
