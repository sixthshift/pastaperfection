import SwiftUI
import Charts
import AppKit
import PastaPerfectionCore

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
/// Apps-using-energy sampler cadence (SPEC §10.5): ticks the app-side
/// libproc shim; a third visible-gated timer alongside the two from §9.6.
private let energyRefreshInterval: TimeInterval = 10.0
/// Rows shown in the Apps Using Significant Energy card (SPEC §10.5).
private let energyCardRowLimit = 5
/// Y-axis floor for the Maximum Capacity chart (SPEC §10.3): health below
/// 50% is a dead battery, so a fixed 50…100 domain keeps week-to-week charts
/// comparable. This is the ONE chart whose floor is above 0, so its
/// `AreaMark` MUST fill from this floor (an `x`/`y`-only AreaMark fills to 0,
/// which lies below the domain and spills the fill out of the plot frame).
private let capacityChartYFloor = 50.0

/// Dashboard palette (AlDente-style dark theme; the window forces
/// `.darkAqua` so these read the same regardless of system appearance).
private enum Palette {
    static let cardBackground = Color.white.opacity(0.06)
    static let chartWell = Color.black.opacity(0.18)
    static let level = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let temperature = Color(red: 0.35, green: 0.62, blue: 0.95)
    static let power = Color(red: 0.68, green: 0.48, blue: 0.95)
    static let limitLine = Color.orange
    static let capacity = Color(red: 0.93, green: 0.72, blue: 0.32)
}

/// Presents `StatsView` in a plain `NSWindow` rather than a SwiftUI `Window`
/// scene, so opening the Stats window doesn't require adding a second scene
/// to `PastaPerfectionApp` (which is out of scope for this ticket's file contract).
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
        // own hosting window (`occlusionState`, for the live-refresh timers'
        // no-op-when-not-visible gate, SPEC §9.6) that a `contentViewController:`
        // convenience init can't supply up front. `occlusionState` — not
        // `isVisible` — is the correct signal here: `isVisible` stays true
        // while the display is asleep or the window is fully covered, which
        // is exactly when these timers must stop.
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
/// formatting/derivation logic lives in `PastaPerfectionCore` (`StatsFormatting`,
/// `StatsDerived`) — this view only renders.
struct StatsView: View {
    @ObservedObject var model: DaemonClientModel
    /// The hosting `NSWindow` (set once by `StatsWindowPresenter`). `weak`
    /// because the window already owns this view (via its
    /// `NSHostingController`) — a strong reference back would be a retain
    /// cycle. Used to gate the live-refresh timers on `occlusionState`
    /// (display-asleep/fully-covered aware, unlike `isVisible`) and to
    /// trigger an immediate refresh when occlusion clears.
    weak var window: NSWindow?

    /// Raw (server-downsampled-to-≤2000, not yet client-downsampled)
    /// samples for the currently selected range. Feeds the charts (via
    /// `chartSamples`), the session list, and the time-to-limit rate window.
    @State private var samples: [StatsSample] = []
    @State private var selectedRange: StatsFormatting.DashboardRange = .day
    @State private var liveTimer: Timer?
    @State private var chartsTimer: Timer?
    /// Apps Using Significant Energy card state (SPEC §10.5): in-memory
    /// only, never written to telemetry/archive/config/socket. Populated by
    /// `EnergySampler.sample(limit:)` on `energyTimer`'s 10 s tick.
    @State private var energyEntries: [EnergyEntry] = []
    /// Count of `energyTimer` ticks so far, used only to distinguish "not
    /// enough snapshots yet" (show "Sampling…") from "sampled, and there's
    /// genuinely nothing significant" (an empty list is a legitimate
    /// `topConsumers` result once at least two snapshots exist).
    @State private var energySampleTicks: Int = 0
    @State private var energyTimer: Timer?

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

    /// Adapter's rated/negotiated voltage (SPEC §10.2) — a spec, not a live
    /// measurement; labeled "Voltage" on the rated Power Adapter card.
    private var adapterVoltageText: String {
        guard let voltageMV = currentPayload?.adapter?.voltageMV else { return "--" }
        return StatsFormatting.voltageText(voltageMV: voltageMV)
    }

    /// Adapter's rated/negotiated max current (SPEC §10.2) — a spec, not a
    /// live measurement.
    private var adapterMaxCurrentText: String {
        guard let currentMA = currentPayload?.adapter?.currentMA else { return "--" }
        return String(format: "%.2f A", Double(currentMA) / 1000)
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

    /// Power Flow widget reading (SPEC §10.4): derived from the live
    /// `get-state` payload's connection/pause flags plus the newest already-
    /// fetched `get-stats` sample's amperage/voltage. Adds zero new
    /// requests — `nil` until both a `get-state` payload and at least one
    /// sample exist.
    private var powerFlow: PowerFlow? {
        guard let payload = currentPayload, let latest = samples.last else { return nil }
        return PowerFlowCore.compute(
            externalConnected: payload.externalConnected,
            isCharging: payload.isCharging,
            chargingPaused: payload.chargingPaused,
            amperageMA: latest.amperageMA,
            voltageMV: latest.voltageMV
        )
    }

    /// A single plottable point on the Maximum Capacity chart (SPEC §10.3).
    private struct CapacityPoint: Equatable {
        let timestamp: Date
        let percent: Double
    }

    /// Maximum Capacity chart points (SPEC §10.3): `maxCapacityMAh /
    /// designCapacity * 100` over the selected-range `chartSamples`, samples
    /// with no capacity reading skipped (never zeroed) via `compactMap`.
    /// Empty when there's no `designCapacity` to divide by.
    private var capacityChartPoints: [CapacityPoint] {
        guard let designCapacity = currentPayload?.health.designCapacity, designCapacity > 0 else {
            return []
        }
        return chartSamples.compactMap { sample in
            guard let maxCapacityMAh = sample.maxCapacityMAh else { return nil }
            let percent = Double(maxCapacityMAh) / Double(designCapacity) * 100
            return CapacityPoint(timestamp: sample.timestamp, percent: percent)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                specCardsRow

                HStack(alignment: .top, spacing: 16) {
                    powerFlowCard
                    energyCard
                }

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
                        capacityCard
                    }
                    HStack(alignment: .top, spacing: 16) {
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
        // Occlusion, not visibility, is what actually stops the timer ticks
        // below (`window?.occlusionState.contains(.visible)`), so restoring
        // visibility (display wakes, window uncovered/un-minimized/back on
        // Space) needs its own catch-up refresh — otherwise the user stares
        // at up-to-60 s-stale charts until the next tick happens to land.
        // Filters by `object` so this only reacts to *this* window's
        // notifications.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
        ) { _ in
            guard window?.occlusionState.contains(.visible) == true else { return }
            model.refresh()
            Task { await loadStats() }
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
                specRow("Voltage:", adapterVoltageText)
                specRow("Max Current:", adapterMaxCurrentText)
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

    /// Maximum Capacity chart (SPEC §10.3): fourth chart card, fixed 50…100
    /// y-domain, headline is the same health % the Battery Health spec card
    /// shows. No paused shading. A placeholder replaces the chart entirely
    /// when there isn't at least one plottable point yet.
    private var capacityCard: some View {
        card {
            chartHeader(title: "Maximum Capacity", value: healthPercentText)
            chartWell {
                if capacityChartPoints.isEmpty {
                    Text("Not enough history yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    Chart(capacityChartPoints, id: \.timestamp) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Floor", capacityChartYFloor),
                            yEnd: .value("Capacity %", point.percent)
                        )
                        .foregroundStyle(chartGradient(Palette.capacity))
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Capacity %", point.percent)
                        )
                        .foregroundStyle(Palette.capacity)
                    }
                    .chartYScale(domain: capacityChartYFloor...100)
                }
            }
        }
    }

    /// Power Flow widget (SPEC §10.4): adapter glyph — watts pill — laptop
    /// glyph, with the side matching `powerFlow.direction` emphasized. Zero
    /// new requests — reads `currentPayload` + `samples.last`, both already
    /// fetched by the existing 5 s/60 s ticks. Hidden (placeholder text)
    /// until both exist.
    private var powerFlowCard: some View {
        card {
            cardHeader(icon: "bolt.horizontal.fill", title: "Power Flow")
            if let flow = powerFlow {
                HStack(spacing: 16) {
                    Image(systemName: "powerplug.fill")
                        .font(.title2)
                        .foregroundStyle(flow.direction == .battery ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.level))
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f W", flow.watts))
                            .font(.title3)
                            .bold()
                            .monospacedDigit()
                        Text("Battery flow")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "laptopcomputer")
                        .font(.title2)
                        .foregroundStyle(flow.direction == .battery ? AnyShapeStyle(Palette.level) : AnyShapeStyle(.secondary))
                }
                .padding(.vertical, 10)
            } else {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
    }

    /// Apps Using Significant Energy card (SPEC §10.5): top ≤ 5 rows from
    /// `energyEntries`, refreshed by `energyTimer`. Icon/name resolve
    /// against `NSRunningApplication` when the pid is a running app (a
    /// generic gear glyph / the sampler's raw `proc_name` otherwise).
    private var energyCard: some View {
        card {
            cardHeader(icon: "cpu", title: "Apps Using Significant Energy")
            if energySampleTicks < 2 {
                Text("Sampling\u{2026}")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if energyEntries.isEmpty {
                Text("No significant activity")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(energyEntries, id: \.pid) { entry in
                        HStack(spacing: 8) {
                            energyIcon(for: entry)
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(energyDisplayName(for: entry))
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func energyIcon(for entry: EnergyEntry) -> Image {
        if let icon = NSRunningApplication(processIdentifier: entry.pid)?.icon {
            return Image(nsImage: icon)
        }
        return Image(systemName: "gearshape.fill")
    }

    private func energyDisplayName(for entry: EnergyEntry) -> String {
        NSRunningApplication(processIdentifier: entry.pid)?.localizedName ?? entry.name
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

    /// Starts the three live-refresh `Timer`s (SPEC §9.6/§10.5), idempotently
    /// — safe to call more than once (e.g. if `.task` re-runs) since it
    /// no-ops once all three timers exist. Deliberately never torn down on
    /// `onDisappear`: the hosting window is retained for the app's lifetime
    /// (`StatsWindowPresenter`), so "disappear" (window closed/hidden) isn't
    /// a real teardown — each tick instead no-ops via the
    /// `window?.occlusionState.contains(.visible)` guard below. Occlusion,
    /// not `isVisible`, is the gate: `isVisible` stays true through a sleeping
    /// display or a fully-covered window, which is exactly when these ticks
    /// must stop doing work (power-draw hardening, T035).
    private func startTimersIfNeeded() {
        if liveTimer == nil {
            let timer = Timer(timeInterval: liveRefreshInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard window?.occlusionState.contains(.visible) == true else { return }
                    model.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
        if chartsTimer == nil {
            let timer = Timer(timeInterval: chartsRefreshInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard window?.occlusionState.contains(.visible) == true else { return }
                    await loadStats()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            chartsTimer = timer
        }
        if energyTimer == nil {
            let timer = Timer(timeInterval: energyRefreshInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard window?.occlusionState.contains(.visible) == true else { return }
                    energyEntries = EnergySampler.sample(limit: energyCardRowLimit)
                    energySampleTicks += 1
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            energyTimer = timer
        }
    }
}
