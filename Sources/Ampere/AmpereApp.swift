import AmpereCore

// Minimal stub entry point. The real SwiftUI MenuBarExtra app (with
// NSApp.setActivationPolicy(.accessory)) arrives in a later ticket (Phase 2).
@main
struct AmpereApp {
    static func main() {
        print("Ampere \(Version.string)")
    }
}
