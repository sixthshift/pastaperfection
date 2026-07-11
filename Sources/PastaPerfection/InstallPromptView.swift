import SwiftUI
import PastaPerfectionCore

/// Resolves the path to the `pastaperfection-cli` binary the install command should
/// invoke. Two cases:
/// - Bundled (`dist/PastaPerfection.app`, built by `scripts/make-app.sh`, which copies
///   `pastaperfection-cli` into `Contents/Resources/`): use `Bundle.main.resourceURL`.
/// - Bare binary (`swift build`, running `.build/debug/PastaPerfection` directly —
///   `Bundle.main.resourceURL` is nil/useless in that case): fall back to
///   the sibling `pastaperfection-cli` next to the running executable, i.e. the repo's
///   `.build/debug/pastaperfection-cli`.
enum CLIPathResolver {
    static func pastaperfectionCLIPath() -> String {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("pastaperfection-cli").path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // Fallback: dev/bare-binary case. `Bundle.main.bundlePath` for a
        // non-bundled executable is the directory containing it (e.g.
        // `.build/debug`), so `pastaperfection-cli` should be right alongside it.
        return (Bundle.main.bundlePath as NSString).appendingPathComponent("pastaperfection-cli")
    }
}

/// Shown in place of the popover's normal state when
/// `DaemonClientModel.viewState == .daemonUnavailable` (SPEC §5 Phase 2:
/// "daemon-not-installed state with install instructions"). The daemon is a
/// one-time root-installed `launchd` service (SPEC §3) — this view explains
/// that and gives the user a copyable install command rather than requiring
/// them to hunt for the CLI path themselves.
struct InstallPromptView: View {
    private var installCommand: String {
        "sudo \(CLIPathResolver.pastaperfectionCLIPath()) install"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Daemon not installed", systemImage: StatusFormatting.glyph(for: .daemonUnavailable))
                .font(.headline)
            Text("PastaPerfection controls charging through a small root daemon that runs once, in the background, at login. It isn't installed (or isn't running) yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Run this once in Terminal, then reopen this menu:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(installCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
