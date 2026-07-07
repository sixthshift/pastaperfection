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

/// Dashboard palette (AlDente-style dark theme; the window forces
/// `.darkAqua` so these read the same regardless of system appearance).
private enum Palette {
    static let cardBackground = Color.white.opacity(0.06)
    static let chartWell = Color.black.opacity(0.18)
    static let level = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let temperature = Color(red: 0.35, green: 0.62, blue: 0.95)
    static let power = Color(red: 0.68, green: 0.48, blue: 0.95)
    static let limitLine = Color.orange
}

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
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Dashboard"
        newWindow.setContentSize(NSSize(width: 920, height: 720))
        newWindow.contentMinSize = NSSize(width: 760, height: 560)
        // The dashboard's card palette is designed dark (AlDente-style);
        // pinning the appearance keeps it consistent under light mode too.
        newWindow.appearance = NSAppearance(named: .darkAqua)
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
/// dashboard — spec cards (battery/health/adapter), a range picker, three
/// Swift Charts (battery %, temperature, power) with paused-region shading,
/// and a session list, laid out as a card grid. All judgeable
/// formatting/derivation logic lives in `AmpereCore` (`StatsFormatting`,
/// `StatsDerived`) — this view only renders.
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
        return String(format: "%.1f %%", percent)
    }

    private var temperatureText: String {
        guard let payload = currentPayload else { return "--" }
        return String(format: "%.1f\u{00B0}C", payload.temperatureC)
    }

    /// Current wattage headline. SPEC §5 Phase 3 wants `Amperage x Voltage /
    /// 1e6` (`StatsFormatting.watts`), computed from the most recently
    /// fetched `get-stats` sample. Shows "N/A" only when no samples have
    /// been fetched yet.
    private var wattsText: String {
        guard let latest = samples.last else { return "N/A" }
        return StatsFormatting.watts(amperageMA: latest.amperageMA, voltageMV: latest.voltageMV)
    }

    private var voltageText: String {
        guard let latest = samples.last else { return "--" }
        return StatsFormatting.voltageText(voltageMV: latest.voltageMV)
    }

    private var amperageText: String {
        guard let latest = samples.last else { return "--" }
        return StatsFormatting.amperageText(amperageMA: latest.amperageMA)
    }

    private var chargerText: String {
        StatsFormatting.chargerText(currentPayload?.adapter)
    }

    private var chargeStatusText: String {
        guard let payload = currentPayload else { return "--" }
        if payload.chargingPaused { return "Paused" }
        if payload.isCharging { return "Charging" }
        return payload.externalConnected ? "Not charging" : "On battery"
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
                specCardsRow

                HStack {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(StatsFormatting.DashboardRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .onChange(of: selectedRange) { _, _ in
                        Task { await loadStats() }
                    }
                    Spacer()
                    Button {
                        model.refresh()
                        Task { await loadStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }

                if chartSamples.isEmpty {
                    card {
                        Text("No telemetry yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 60)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        batteryLevelCard
                        temperatureCard
                    }
                    HStack(alignment: .top, spacing: 16) {
                        powerCard
                        sessionsCard
                    }
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await loadStats()
            startTimersIfNeeded()
        }
    }

    // MARK: - Spec cards (top row)

    private var specCardsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            card {
                cardHeader(icon: "bolt.fill", title: "Battery Specs")
                specRow("Current:", amperageText)
                specRow("Voltage:", voltageText)
                specRow("Power:", wattsText)
                specRow("Status:", chargeStatusText)
                specRow("Charge Limit:", currentPayload.map { "\($0.limit) %" } ?? "--")
                specRow("Battery Charge:", currentPayload.map { "\($0.percent) %" } ?? "--")
            }
            card {
                cardHeader(icon: "heart.fill", title: "Battery Health")
                specRow(
                    "Design Capacity:",
                    currentPayload.map { "\($0.health.designCapacity) mAh" } ?? "--"
                )
                specRow(
                    "Maximum Capacity:",
                    currentPayload.map { "\($0.health.maxCapacity) mAh" } ?? "--"
                )
                specRow("Health:", healthPercentText)
                specRow("Cycle Count:", currentPayload.map { "\($0.health.cycleCount)" } ?? "--")
                specRow("Temperature:", temperatureText)
            }
            card {
                cardHeader(icon: "powerplug.fill", title: "Power Adapter")
                specRow("Adapter:", chargerText)
                specRow(
                    "Power:",
                    currentPayload?.adapter.map { "\($0.watts) W" } ?? "--"
                )
                specRow(
                    "Adapter State:",
                    currentPayload.map { $0.adapterDisabled ? "Disabled" : "Enabled" } ?? "--"
                )
                specRow("Mode:", currentPayload?.mode.capitalized ?? "--")
            }
        }
    }

    // MARK: - Chart cards

    private var batteryLevelCard: some View {
        card {
            chartHeader(
                title: "Battery Level",
                value: currentPayload.map { "\($0.percent) %" } ?? "--",
                detailTitle: timeEstimateText == nil ? nil : "Time to limit",
                detailValue: timeEstimateText
            )
            chartWell {
                Chart {
                    ForEach(pausedIntervals, id: \.start) { interval in
                        RectangleMark(
                            xStart: .value("Start", interval.start),
                            xEnd: .value("End", interval.end)
                        )
                        .foregroundStyle(pausedShadingColor)
                    }
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Percent", sample.percent)
                        )
                        .foregroundStyle(chartGradient(Palette.level))
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Percent", sample.percent)
                        )
                        .foregroundStyle(Palette.level)
                    }
                    if let limit = currentPayload?.limit {
                        RuleMark(y: .value("Limit", limit))
                            .foregroundStyle(Palette.limitLine.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartYScale(domain: 0...100)
            }
        }
    }

    private var temperatureCard: some View {
        card {
            chartHeader(title: "Battery Temperature", value: temperatureText)
            chartWell {
                Chart(chartSamples, id: \.timestamp) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("\u{00B0}C", sample.temperatureC)
                    )
                    .foregroundStyle(chartGradient(Palette.temperature))
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("\u{00B0}C", sample.temperatureC)
                    )
                    .foregroundStyle(Palette.temperature)
                }
            }
        }
    }

    private var powerCard: some View {
        card {
            chartHeader(title: "Power Consumption", value: wattsText)
            chartWell {
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
                        .foregroundStyle(Palette.power)
                    }
                }
            }
        }
    }

    private var sessionsCard: some View {
        card {
            cardHeader(icon: "list.bullet", title: "Sessions")
            if displaySessions.isEmpty {
                Text("No sessions yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(displaySessions.enumerated()), id: \.offset) { _, session in
                        Text(StatsFormatting.sessionRowText(session))
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Card building blocks

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
            .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cardHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.callout)
            Text(title)
                .font(.headline)
        }
        .padding(.bottom, 4)
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func chartHeader(
        title: String,
        value: String,
        detailTitle: String? = nil,
        detailValue: String? = nil
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2)
                    .bold()
                    .monospacedDigit()
            }
            Spacer()
            if let detailTitle, let detailValue {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detailTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(detailValue)
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        }
    }

    private func chartWell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(height: 160)
            .background(Palette.chartWell, in: RoundedRectangle(cornerRadius: 10))
    }

    private func chartGradient(_ color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.35), color.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
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
