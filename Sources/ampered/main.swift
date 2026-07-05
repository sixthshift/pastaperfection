//
// main.swift
// ampered
//
// The root daemon's entry point (SPEC §3). Refuses to run unless started as
// root (euid 0) — it is the only process permitted to write SMC keys, and a
// non-root run would silently do nothing useful while masking a real
// install/launchd misconfiguration, so it fails loudly instead.
//

import AmpereCore
import Darwin
import Foundation

guard geteuid() == 0 else {
    let message = "ampered: must run as root (uid 0) — this daemon writes SMC keys directly " +
        "and is meant to be started by launchd as root, not run standalone.\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

let daemon = Daemon()
daemon.run()
