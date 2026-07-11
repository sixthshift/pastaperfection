import SwiftUI
import AppKit
import PastaPerfectionCore

/// The real SwiftUI `MenuBarExtra` app (SPEC §2, §5 Phase 2). Sets
/// `NSApp.setActivationPolicy(.accessory)` at launch (via the app delegate)
/// so PastaPerfection never shows a Dock icon or menu bar app-switcher entry — it
/// lives only as the `MenuBarExtra` item.
@main
struct PastaPerfectionApp: App {
    @NSApplicationDelegateAdaptor(PastaPerfectionAppDelegate.self) private var appDelegate
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
final class PastaPerfectionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
