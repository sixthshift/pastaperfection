import PastaPerfectionCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

// `install` / `uninstall` / `state` / `req` (SPEC §5 Phase 1; `req` added by
// T024 as a well-behaved `nc -U` replacement for scripts/hw-gate.sh) route to
// `InstallCommands`; every other subcommand keeps going to the Phase 0 spike
// commands, unchanged.
if let command = arguments.first, ["install", "uninstall", "state", "req"].contains(command) {
    exit(InstallCommands.run(command: command, args: Array(arguments.dropFirst())))
}

exit(SpikeCommands.run(arguments))
