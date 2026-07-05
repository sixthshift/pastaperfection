import AmpereCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

// `install` / `uninstall` / `state` (SPEC §5 Phase 1) route to
// `InstallCommands`; every other subcommand keeps going to the Phase 0 spike
// commands, unchanged.
if let command = arguments.first, ["install", "uninstall", "state"].contains(command) {
    exit(InstallCommands.run(command: command, args: Array(arguments.dropFirst())))
}

exit(SpikeCommands.run(arguments))
