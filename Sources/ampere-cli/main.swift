import AmpereCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
exit(SpikeCommands.run(arguments))
