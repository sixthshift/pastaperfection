import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (SPEC §2: "Launch-at-login:
/// `SMAppService.mainApp.register()` from the bundled app"). Registering a
/// login item only makes sense when PastaPerfection is running from inside a proper
/// app bundle (`dist/PastaPerfection.app`, installed via `scripts/make-app.sh`) — a
/// bare `.build/debug/PastaPerfection` binary has no bundle identifier and
/// `SMAppService` either throws or is meaningless in that context. Kept as
/// its own type (not inline in the view) so it's swappable/mockable and so
/// `MenuBarView` never touches `SMAppService` directly.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Running as a bare binary (no bundle identifier) — the toggle should
    /// be hidden entirely rather than shown disabled, since registering a
    /// login item for a non-bundled executable doesn't work.
    case unavailable
}

public enum LoginItem {
    /// Whether the current process is running from inside a real app bundle
    /// (has a `CFBundleIdentifier`). `Bundle.main.bundleIdentifier == nil`
    /// for a bare executable built by `swift build` and run from
    /// `.build/(debug|release)/PastaPerfection` directly.
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Current login-item status. `.unavailable` when not running from a
    /// bundle; otherwise reflects `SMAppService.mainApp.status`.
    public static var status: LoginItemStatus {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        default:
            return .disabled
        }
    }

    /// Registers PastaPerfection as a login item. No-op (returns `false`) when
    /// `isAvailable` is false. Errors from `SMAppService` are swallowed —
    /// callers read `status` afterwards to see whether it took effect,
    /// consistent with the rest of the app's daemon-unavailable-style
    /// failure handling (never crash the menu bar app over this).
    @discardableResult
    public static func register() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            return false
        }
    }

    /// Unregisters PastaPerfection as a login item. No-op (returns `false`) when
    /// `isAvailable` is false.
    @discardableResult
    public static func unregister() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            return false
        }
    }

    /// Convenience used by the popover toggle: set the desired enabled
    /// state, registering/unregistering as needed.
    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }
}
