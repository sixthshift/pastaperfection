import Foundation

/// Pure, testable formatting helpers for the menu bar app's status glyph and
/// label (Phase 2 / SPEC §2 MenuBarExtra). No IOKit, no SwiftUI — just string
/// mapping so this is unit-testable without a UI.
public enum StatusFormatting {
    /// The distinct visual states the menu bar glyph needs to distinguish at
    /// a glance. Deliberately coarser than `GetStatePayload`/`PauseReason` —
    /// callers derive one of these from the live state before calling
    /// `glyph(for:)`.
    public enum GlyphState: Equatable, Sendable {
        /// Plugged in and actively charging.
        case charging
        /// Plugged in, charging paused because the limit was reached
        /// (or sailing/heat hold) — i.e. `chargingPaused == true`.
        case pausedAtLimit
        /// Plugged in but the adapter itself is electrically disabled
        /// (discharge-to-limit in progress) — running on battery while
        /// connected to power.
        case adapterOffDischarging
        /// On battery, not connected to external power at all.
        case dischargingUnplugged
        /// The daemon can't be reached (socket absent/refused/timed out).
        case daemonUnavailable
    }

    /// SF Symbol name for a given glyph state. Every case maps to a distinct
    /// symbol so the menu bar reads unambiguously at a glance.
    public static func glyph(for state: GlyphState) -> String {
        switch state {
        case .charging:
            return "bolt.fill"
        case .pausedAtLimit:
            return "pause.circle.fill"
        case .adapterOffDischarging:
            return "bolt.slash.fill"
        case .dischargingUnplugged:
            return "battery.75"
        case .daemonUnavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Menu bar / popover percent label, e.g. `label(percent: 75) == "75%"`.
    public static func label(percent: Int) -> String {
        "\(percent)%"
    }
}
