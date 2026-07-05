import SwiftUI
import AppKit
import AmpereCore

/// The real SwiftUI `MenuBarExtra` app (SPEC §2, §5 Phase 2). Sets
/// `NSApp.setActivationPolicy(.accessory)` at launch (via the app delegate)
/// so Ampere never shows a Dock icon or menu bar app-switcher entry — it
/// lives only as the `MenuBarExtra` item.
@main
struct AmpereApp: App {
    @NSApplicationDelegateAdaptor(AmpereAppDelegate.self) private var appDelegate
    @StateObject private var daemonClient = DaemonClientModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: daemonClient)
        } label: {
            MenuBarLabel(model: daemonClient)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Minimal app delegate whose only job is the activation-policy switch
/// (SPEC §2: "The app sets `NSApp.setActivationPolicy(.accessory)` at
/// launch"). No windows, no other AppKit behavior.
final class AmpereAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
