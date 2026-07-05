//
// SpikeCommands.swift
// ampere-cli
//
// Phase 0 spike commands (SPEC §5): `status`, `keys`, `pause`, `resume`,
// `adapter on|off`. Hand-rolled argument parsing — zero third-party
// dependencies (locked, SPEC §2).
//
// Only `ampere-cli` (Phase 0 spike commands) and `ampered` are permitted to
// write SMC keys (SPEC §3). This file writes ONLY the SPEC §4 allowlist:
// CHTE, CH0B, CH0C, CHIE, CH0I — never any other key.
//

import AmpereCore
import Darwin
import Foundation

public enum SpikeCommands {

    /// The SPEC §4 write allowlist, in the order `keys` prints them.
    static let allowlistKeys = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I"]

    // MARK: Dispatch

    /// Parse `args` (already stripped of the executable name) and run the
    /// matching subcommand. Returns the process exit code.
    public static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else {
            // No subcommand: keep it simple — usage (which includes the
            // version line) and exit 0.
            printUsage()
            return 0
        }

        switch command {
        case "version":
            print("ampere-cli \(Version.string)")
            return 0
        case "status":
            return runStatus()
        case "keys":
            return runKeys()
        case "pause":
            return runPause()
        case "resume":
            return runResume()
        case "adapter":
            return runAdapter(Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
            return 0
        default:
            writeStderr("ampere-cli: unknown subcommand '\(command)'\n")
            printUsage(toStderr: true)
            return 64
        }
    }

    // MARK: status

    static func runStatus() -> Int32 {
        let reading = BatteryReader.readLive()
        print(statusJSON(reading))
        return 0
    }

    static func statusJSON(_ r: BatteryReading) -> String {
        """
        {"percent":\(r.percent),"isCharging":\(r.isCharging),"externalConnected":\(r.externalConnected),"temperatureC":\(formatDouble(r.temperatureC)),"cycleCount":\(r.cycleCount),"maxCapacity":\(r.appleRawMaxCapacity),"designCapacity":\(r.designCapacity)}
        """
    }

    static func formatDouble(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    // MARK: keys

    static func runKeys() -> Int32 {
        let smc = SMC()
        do {
            try smc.open()
        } catch {
            writeStderr("ampere-cli: failed to open SMC connection: \(error)\n")
            return 1
        }
        defer { smc.close() }

        for keyStr in allowlistKeys {
            let key = FourCharCode(fromString: keyStr)
            do {
                if let info = try smc.keyInformation(key) {
                    print("\(keyStr) exists=true type=\(info.type.toString()) size=\(info.size)")
                } else {
                    print("\(keyStr) exists=false")
                }
            } catch {
                print("\(keyStr) exists=unknown error=\(error)")
            }
        }
        return 0
    }

    // MARK: pause / resume (charging inhibit, SPEC §4 fallback order)

    static func runPause() -> Int32 {
        guard requireRoot("pause") else { return 1 }
        return setChargingInhibited(true)
    }

    static func runResume() -> Int32 {
        guard requireRoot("resume") else { return 1 }
        return setChargingInhibited(false)
    }

    /// `inhibited == true` -> pause charging; `false` -> resume charging.
    /// Fallback order per SPEC §4: try `CHTE` first (probed type/size,
    /// values 1/0); if `CHTE` doesn't exist on this firmware, write both
    /// `CH0B` and `CH0C` (ui8, 0x02 inhibit / 0x00 allow).
    static func setChargingInhibited(_ inhibited: Bool) -> Int32 {
        let smc = SMC()
        do {
            try smc.open()
        } catch {
            writeStderr("ampere-cli: failed to open SMC connection: \(error)\n")
            return 1
        }
        defer { smc.close() }

        let chteKey = FourCharCode(fromString: "CHTE")
        do {
            if let info = try smc.keyInformation(chteKey) {
                let value: UInt32 = inhibited ? 1 : 0
                let bytes = encodeValue(value, size: info.size)
                try smc.writeData(chteKey, bytes: bytes)
                let readback = try smc.readData(chteKey)
                printWriteResult(key: "CHTE", written: bytes, writeSize: info.size, readback: readback)
                return 0
            }
        } catch {
            writeStderr("ampere-cli: CHTE write failed: \(error)\n")
            return 1
        }

        // CHTE not present on this firmware — fall back to CH0B + CH0C.
        let fallbackValue: UInt32 = inhibited ? 0x02 : 0x00
        do {
            for keyStr in ["CH0B", "CH0C"] {
                let key = FourCharCode(fromString: keyStr)
                guard let info = try smc.keyInformation(key) else {
                    writeStderr("ampere-cli: neither CHTE nor \(keyStr) exist on this firmware\n")
                    return 1
                }
                let bytes = encodeValue(fallbackValue, size: info.size)
                try smc.writeData(key, bytes: bytes)
                let readback = try smc.readData(key)
                printWriteResult(key: keyStr, written: bytes, writeSize: info.size, readback: readback)
            }
            return 0
        } catch {
            writeStderr("ampere-cli: CH0B/CH0C write failed: \(error)\n")
            return 1
        }
    }

    // MARK: adapter on|off (SPEC §4 fallback order)

    static func runAdapter(_ args: [String]) -> Int32 {
        guard let mode = args.first, mode == "on" || mode == "off" else {
            writeStderr("ampere-cli: usage: ampere-cli adapter on|off\n")
            return 64
        }

        guard requireRoot("adapter \(mode)") else { return 1 }

        let disable = (mode == "off")
        let smc = SMC()
        do {
            try smc.open()
        } catch {
            writeStderr("ampere-cli: failed to open SMC connection: \(error)\n")
            return 1
        }
        defer { smc.close() }

        let chieKey = FourCharCode(fromString: "CHIE")
        do {
            if let info = try smc.keyInformation(chieKey) {
                let value: UInt32 = disable ? 0x08 : 0x00
                let bytes = encodeValue(value, size: info.size)
                try smc.writeData(chieKey, bytes: bytes)
                let readback = try smc.readData(chieKey)
                printWriteResult(key: "CHIE", written: bytes, writeSize: info.size, readback: readback)
                return 0
            }
        } catch {
            writeStderr("ampere-cli: CHIE write failed: \(error)\n")
            return 1
        }

        // CHIE not present on this firmware — fall back to CH0I.
        do {
            let ch0iKey = FourCharCode(fromString: "CH0I")
            guard let info = try smc.keyInformation(ch0iKey) else {
                writeStderr("ampere-cli: neither CHIE nor CH0I exist on this firmware\n")
                return 1
            }
            let value: UInt32 = disable ? 0x01 : 0x00
            let bytes = encodeValue(value, size: info.size)
            try smc.writeData(ch0iKey, bytes: bytes)
            let readback = try smc.readData(ch0iKey)
            printWriteResult(key: "CH0I", written: bytes, writeSize: info.size, readback: readback)
            return 0
        } catch {
            writeStderr("ampere-cli: CH0I write failed: \(error)\n")
            return 1
        }
    }

    // MARK: Root guard

    /// Root guard for any write-capable command. On failure: prints a clear
    /// error mentioning root to stderr and returns false. Callers must exit
    /// 1 and must NOT perform any SMC write in this case.
    static func requireRoot(_ action: String) -> Bool {
        if geteuid() != 0 {
            writeStderr("ampere-cli: '\(action)' requires root privileges (run with sudo)\n")
            return false
        }
        return true
    }

    // MARK: Byte encoding helpers (SMCBytes is a 32-tuple; no direct indexing)

    /// Encode `value` as `size` big-endian bytes (clamped to 1...4) at the
    /// start of a zero-filled `SMCBytes` buffer.
    static func encodeValue(_ value: UInt32, size: UInt32) -> SMCBytes {
        var arr = [UInt8](repeating: 0, count: 32)
        let n = Int(max(1, min(size, 4)))
        var v = value
        for i in stride(from: n - 1, through: 0, by: -1) {
            arr[i] = UInt8(v & 0xff)
            v >>= 8
        }
        return makeSMCBytes(arr)
    }

    static func makeSMCBytes(_ array: [UInt8]) -> SMCBytes {
        var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<min(array.count, 32) {
                raw[i] = array[i]
            }
        }
        return bytes
    }

    static func hexBytes(_ bytes: SMCBytes, count: Int) -> String {
        let n = max(1, min(count, 32))
        var result: [UInt8] = []
        withUnsafeBytes(of: bytes) { raw in
            for i in 0..<n {
                result.append(raw[i])
            }
        }
        return result.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func printWriteResult(
        key: String,
        written: SMCBytes,
        writeSize: UInt32,
        readback: (bytes: SMCBytes, type: FourCharCode, size: UInt32)
    ) {
        print("\(key) wrote=[\(hexBytes(written, count: Int(writeSize)))] " +
              "readback=[\(hexBytes(readback.bytes, count: Int(readback.size)))]")
    }

    // MARK: Usage / errors

    static func writeStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    static func printUsage(toStderr: Bool = false) {
        let text = """
        ampere-cli \(Version.string)
        Usage: ampere-cli <command> [args]

        Commands:
          status               Print live battery state as JSON (no root)
          keys                 Print SPEC §4 allowlist key info (no root)
          pause                Inhibit charging (requires root)
          resume               Allow charging (requires root)
          adapter on|off       Enable/disable the charge adapter (requires root)
          version              Print version
        """
        if toStderr {
            writeStderr(text + "\n")
        } else {
            print(text)
        }
    }
}
