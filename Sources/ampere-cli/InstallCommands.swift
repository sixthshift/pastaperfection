//
// InstallCommands.swift
// ampere-cli
//
// `install` / `uninstall` / `state` (SPEC §3, §5 Phase 1):
// - install: copy the daemon binary to /Library/PrivilegedHelperTools, write
//   the launchd plist to /Library/LaunchDaemons, `launchctl bootstrap` it
//   into the system domain.
// - uninstall: `launchctl bootout`, remove plist + binary + the socket file.
//   Leaves config untouched (SPEC: daemon owns config; uninstall doesn't
//   touch user settings).
// - state: `get-state` over the socket, no root, pretty-printed.
//
// `--dry-run` on install/uninstall prints every planned action (one per
// line) without executing anything and without requiring root.
//

import AmpereCore
import Darwin
import Foundation

public enum InstallCommands {
    static let label = "com.ampere.daemon"
    static let helperToolDirectory = "/Library/PrivilegedHelperTools"
    static let helperToolPath = "/Library/PrivilegedHelperTools/ampered"
    static let plistPath = "/Library/LaunchDaemons/com.ampere.daemon.plist"
    static let socketPath = "/var/run/ampere.sock"
    static let bootstrapDomain = "system"
    static let bootoutTarget = "system/com.ampere.daemon"

    /// Dispatches `install`, `uninstall`, or `state`. Returns the process exit code.
    public static func run(command: String, args: [String]) -> Int32 {
        let dryRun = args.contains("--dry-run")
        switch command {
        case "install":
            return runInstall(args, dryRun: dryRun)
        case "uninstall":
            return runUninstall(dryRun: dryRun)
        case "state":
            return runState()
        default:
            writeStderr("ampere-cli: unknown subcommand '\(command)'\n")
            return 64
        }
    }

    // MARK: - install

    static func runInstall(_ args: [String], dryRun: Bool) -> Int32 {
        let sourceBinary = binaryOverride(in: args) ?? defaultSiblingBinaryPath()
        let bootstrapCommand = "launchctl bootstrap \(bootstrapDomain) \(plistPath)"

        if dryRun {
            print("copy \(sourceBinary) -> \(helperToolPath)")
            print("write plist -> \(plistPath)")
            print(bootstrapCommand)
            return 0
        }

        guard requireRoot("install") else { return 1 }

        do {
            try FileManager.default.createDirectory(
                atPath: helperToolDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )

            if FileManager.default.fileExists(atPath: helperToolPath) {
                try FileManager.default.removeItem(atPath: helperToolPath)
            }
            try FileManager.default.copyItem(atPath: sourceBinary, toPath: helperToolPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperToolPath)

            let plist = launchdPlist(label: label, binaryPath: helperToolPath)
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

            let status = runProcess("/bin/launchctl", ["bootstrap", bootstrapDomain, plistPath])
            guard status == 0 else {
                writeStderr("ampere-cli: '\(bootstrapCommand)' failed (exit \(status))\n")
                return 1
            }

            print("installed \(helperToolPath), \(plistPath); bootstrapped into \(bootstrapDomain)")
            return 0
        } catch {
            writeStderr("ampere-cli: install failed: \(error)\n")
            return 1
        }
    }

    /// `--binary <path>` overrides the source binary to copy.
    static func binaryOverride(in args: [String]) -> String? {
        guard let index = args.firstIndex(of: "--binary"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Default source binary: `ampered` living next to the running
    /// `ampere-cli` binary (same directory as `CommandLine.arguments[0]`).
    static func defaultSiblingBinaryPath() -> String {
        let cliPath = CommandLine.arguments[0]
        let directory = (cliPath as NSString).deletingLastPathComponent
        let base = directory.isEmpty ? "." : directory
        return (base as NSString).appendingPathComponent("ampered")
    }

    // MARK: - uninstall

    static func runUninstall(dryRun: Bool) -> Int32 {
        let bootoutCommand = "launchctl bootout \(bootoutTarget)"

        if dryRun {
            print(bootoutCommand)
            print("remove \(plistPath)")
            print("remove \(helperToolPath)")
            return 0
        }

        guard requireRoot("uninstall") else { return 1 }

        // Best-effort: `bootout` fails if the job isn't currently loaded
        // (e.g. a prior crash already dropped it from launchd) — that's not
        // fatal to finishing the rest of the cleanup.
        _ = runProcess("/bin/launchctl", ["bootout", bootoutTarget])

        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: helperToolPath)
        try? FileManager.default.removeItem(atPath: socketPath)

        print("uninstalled \(plistPath), \(helperToolPath), \(socketPath)")
        return 0
    }

    // MARK: - state

    static func runState() -> Int32 {
        let client = SocketClient()
        do {
            try client.connect(path: socketPath)
        } catch {
            writeStderr(
                "ampere-cli: daemon not running (no socket at \(socketPath)): \(error)\n"
            )
            return 1
        }
        defer { client.close() }

        do {
            let requestLine = try ProtocolCodec.encodeLine(Request.getState)
            let responseLine = try client.request(requestLine, timeout: 5)
            let decoded = try ProtocolCodec.decode(GetStateResponse.self, from: responseLine)

            guard decoded.ok, let data = decoded.data else {
                writeStderr("ampere-cli: get-state failed: \(decoded.error ?? "unknown error")\n")
                return 1
            }

            print(try prettyJSON(data))
            return 0
        } catch {
            writeStderr("ampere-cli: get-state request failed: \(error)\n")
            return 1
        }
    }

    static func prettyJSON(_ payload: GetStatePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    static func requireRoot(_ action: String) -> Bool {
        if geteuid() != 0 {
            writeStderr("ampere-cli: '\(action)' requires root privileges (run with sudo)\n")
            return false
        }
        return true
    }

    @discardableResult
    static func runProcess(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            writeStderr("ampere-cli: failed to run \(path): \(error)\n")
            return 1
        }
    }

    static func writeStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
