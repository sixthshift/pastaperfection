import Testing
import Foundation
@testable import PastaPerfectionCore

/// Tests for `launchdPlist(label:binaryPath:)` (SPEC §3: launchd label
/// `com.ampere.daemon`, `RunAtLoad=true`, `KeepAlive=true`). Oracle.md Phase 1:
/// "`pastaperfection-cli install --dry-run` prints plist path + bootstrap command" —
/// this suite covers the plist content itself is valid and carries the right
/// fields; `InstallCommands` (pastaperfection-cli target) is the one that writes it.
@Suite struct PlistTests {
    @Test func containsLabelBinaryPathAndRunAtLoad() {
        let xml = launchdPlist(label: "com.ampere.daemon", binaryPath: "/Library/PrivilegedHelperTools/ampered")

        #expect(xml.contains("com.ampere.daemon"))
        #expect(xml.contains("/Library/PrivilegedHelperTools/ampered"))
        #expect(xml.contains("<key>RunAtLoad</key>"))
        #expect(xml.contains("<key>KeepAlive</key>"))
        #expect(xml.contains("<true/>"))
    }

    @Test func programArgumentsIsAnArrayContainingOnlyTheBinaryPath() {
        let xml = launchdPlist(label: "com.ampere.daemon", binaryPath: "/tmp/pastaperfectiond")
        #expect(xml.contains("<key>ProgramArguments</key>"))
        #expect(xml.contains("<array>"))
        #expect(xml.contains("<string>/tmp/pastaperfectiond</string>"))
    }

    /// Writes the generated plist to a temp file and lints it with the real
    /// `plutil` binary (via `Process`) — catches malformed XML/plist
    /// structure that a plain string-contains check would miss.
    @Test func passesPlutilLint() throws {
        let xml = launchdPlist(label: "com.ampere.daemon", binaryPath: "/Library/PrivilegedHelperTools/ampered")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastaperfection-plist-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try xml.write(to: tempURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", tempURL.path]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }
}
