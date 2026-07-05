//
// SMCAdapter.swift
// AmpereCore
//
// The ONLY module that turns `ChargingCommand`s into SMC writes (SPEC §3:
// "Only `ampered` ... ever writes SMC"; SPEC §4: the write allowlist). The
// low-level transport is injected as `SMCWriting` so tests exercise this
// type against a fake — no IOKit, no root, no hardware involved. The live
// path is the existing `SMC` client (`SMC.swift`), which already has this
// exact method shape and is declared conformant below.
//
// Allowlist enforcement (SPEC §4 — "writing any other key = drift, halt")
// is structural: the only SMC key strings that ever appear in this file are
// the five string literals `CHTE`, `CH0B`, `CH0C`, `CHIE`, `CH0I`, and the
// public API exposes no generic "write this key" entry point — only the two
// setters (`setChargingInhibited`, `setAdapterDisabled`), `probe()`, and
// `apply(_:)`.
//

import Foundation

/// Low-level SMC transport needed by `SMCAdapter`. `SMC` (the live IOKit
/// client, `SMC.swift`) already has this exact method shape; tests inject a
/// fake instead so byte-exactness / idempotence / verify-after-write can be
/// asserted without touching real hardware.
public protocol SMCWriting {
    func keyInformation(_ key: FourCharCode) throws -> (type: FourCharCode, size: UInt32)?
    func readData(_ key: FourCharCode) throws -> (bytes: SMCBytes, type: FourCharCode, size: UInt32)
    func writeData(_ key: FourCharCode, bytes: SMCBytes) throws
}

/// The live client already conforms structurally — this only declares it.
/// No policy is added here; `SMC` remains a generic, allowlist-agnostic
/// transport (see its own header comment).
extension SMC: SMCWriting {}

/// Which inhibit/adapter key exists on this machine's firmware (SPEC §4
/// fallback order), probed once via key-info and cached.
public struct SMCCapabilities: Equatable, Sendable {
    public enum InhibitKey: Equatable, Sendable {
        /// `CHTE` (Tahoe): ui32/4 bytes, little-endian.
        case chte
        /// `CH0B` + `CH0C` (pre-Tahoe fallback): ui8, write both.
        case ch0bCh0c
        /// Neither key exists on this firmware.
        case unavailable
    }

    public enum AdapterKey: Equatable, Sendable {
        /// `CHIE` (Tahoe): confirmed live, 1 byte.
        case chie
        /// `CH0I` (fallback): ui8, 1 byte.
        case ch0i
        /// Neither key exists on this firmware.
        case unavailable
    }

    public var inhibitKey: InhibitKey
    public var adapterKey: AdapterKey

    public init(inhibitKey: InhibitKey, adapterKey: AdapterKey) {
        self.inhibitKey = inhibitKey
        self.adapterKey = adapterKey
    }
}

/// Turns `ChargingCommand`s (SPEC §3.3, emitted by the pure `decide(...)`)
/// into SMC writes, enforcing the SPEC §4 allowlist and write values,
/// idempotently, with post-write verification.
public final class SMCAdapter {
    /// Reads current battery state for post-write verification of a
    /// charging-inhibit change. Injectable for tests; the live daemon
    /// passes `{ BatteryReader.readLive().state }`.
    public typealias BatteryStateReader = () -> BatteryState

    private let writer: SMCWriting
    private let readBattery: BatteryStateReader

    private var capabilities: SMCCapabilities?

    /// Last state actually written to hardware by this adapter instance —
    /// both the idempotence memory ("only write on a real state change")
    /// and, implicitly, what `apply`/the setters compare against. `nil`
    /// means "never written yet".
    private var lastChargingInhibited: Bool?
    private var lastAdapterDisabled: Bool?

    /// True when the most recent write's effect was confirmed:
    /// - charging-inhibit writes: re-read battery state via `readBattery`
    ///   and check `isCharging` flipped consistent with the write.
    /// - adapter writes: read back the key itself via `writer.readData` and
    ///   compare against what was written.
    /// Starts `true` (nothing attempted yet, nothing unverified).
    public private(set) var lastWriteVerified: Bool = true

    public init(
        writer: SMCWriting,
        readBattery: @escaping BatteryStateReader = { BatteryReader.readLive().state }
    ) {
        self.writer = writer
        self.readBattery = readBattery
    }

    // MARK: Probe (SPEC §4 fallback order, cached)

    /// Probes which inhibit key (`CHTE` else `CH0B`+`CH0C`) and adapter key
    /// (`CHIE` else `CH0I`) exist on this firmware. Cached after the first
    /// call — later calls return the same `SMCCapabilities` without
    /// re-probing.
    @discardableResult
    public func probe() -> SMCCapabilities {
        if let cached = capabilities { return cached }

        let inhibitKey: SMCCapabilities.InhibitKey
        if keyExists("CHTE") {
            inhibitKey = .chte
        } else if keyExists("CH0B") && keyExists("CH0C") {
            inhibitKey = .ch0bCh0c
        } else {
            inhibitKey = .unavailable
        }

        let adapterKey: SMCCapabilities.AdapterKey
        if keyExists("CHIE") {
            adapterKey = .chie
        } else if keyExists("CH0I") {
            adapterKey = .ch0i
        } else {
            adapterKey = .unavailable
        }

        let caps = SMCCapabilities(inhibitKey: inhibitKey, adapterKey: adapterKey)
        capabilities = caps
        return caps
    }

    private func keyExists(_ keyStr: String) -> Bool {
        let key = FourCharCode(fromString: keyStr)
        // `try?` on an already-Optional-returning throwing call flattens
        // (Swift 5 language mode, locked SPEC §2) — both "threw" and
        // "returned nil" collapse to nil here, which is exactly "doesn't
        // exist" from this adapter's point of view.
        return (try? writer.keyInformation(key)) != nil
    }

    // MARK: Charging inhibit (SPEC §4)

    /// Inhibit (`true`) or allow (`false`) charging. Writes ONLY the exact
    /// bytes from `docs/smc-findings.md`:
    /// - `CHTE` little-endian ui32: `[01 00 00 00]` inhibited, `[00 00 00 00]` allowed.
    /// - Fallback `CH0B` + `CH0C` (both written): ui8 `0x02` inhibited, `0x00` allowed.
    ///
    /// Idempotent: a call requesting the state this adapter last wrote is a
    /// no-op (no write, no re-verification). After an actual write, re-reads
    /// battery state via the injected reader and sets `lastWriteVerified`.
    public func setChargingInhibited(_ inhibited: Bool) {
        guard lastChargingInhibited != inhibited else { return }

        let caps = probe()
        let wrote: Bool

        switch caps.inhibitKey {
        case .chte:
            write(key: "CHTE", bytes: Self.chteBytes(inhibited: inhibited))
            wrote = true
        case .ch0bCh0c:
            let bytes = Self.makeSMCBytes([inhibited ? 0x02 : 0x00])
            write(key: "CH0B", bytes: bytes)
            write(key: "CH0C", bytes: bytes)
            wrote = true
        case .unavailable:
            wrote = false
        }

        guard wrote else {
            lastWriteVerified = false
            return
        }

        lastChargingInhibited = inhibited
        let observed = readBattery()
        lastWriteVerified = inhibited ? (observed.isCharging == false) : (observed.isCharging == true)
    }

    /// The exact bytes written to `CHTE`: ui32, **little-endian**
    /// (`docs/smc-findings.md`, confirmed live 2026-07-05). `[01 00 00 00]`
    /// inhibited, `[00 00 00 00]` allowed. Never big-endian — firmware
    /// rejects `[00 00 00 01]` with smcResult 137.
    static func chteBytes(inhibited: Bool) -> SMCBytes {
        makeSMCBytes(inhibited ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Adapter disable (SPEC §4)

    /// Disable (`true`) or enable (`false`) the charge adapter. Writes ONLY:
    /// - `CHIE`: `0x08` disabled, `0x00` enabled (confirmed live).
    /// - Fallback `CH0I`: `0x01` disabled, `0x00` enabled.
    ///
    /// Same idempotence rule as `setChargingInhibited`. Verified by reading
    /// back the written key itself via `writer.readData` (the adapter bit is
    /// directly observable — no battery-state proxy needed).
    public func setAdapterDisabled(_ disabled: Bool) {
        guard lastAdapterDisabled != disabled else { return }

        let caps = probe()
        let key: String
        let bytes: SMCBytes

        switch caps.adapterKey {
        case .chie:
            key = "CHIE"
            bytes = Self.makeSMCBytes([disabled ? 0x08 : 0x00])
        case .ch0i:
            key = "CH0I"
            bytes = Self.makeSMCBytes([disabled ? 0x01 : 0x00])
        case .unavailable:
            lastWriteVerified = false
            return
        }

        write(key: key, bytes: bytes)
        lastAdapterDisabled = disabled
        lastWriteVerified = verifyReadback(key: key, expected: bytes)
    }

    private func verifyReadback(key: String, expected: SMCBytes) -> Bool {
        guard let readback = try? writer.readData(FourCharCode(fromString: key)) else {
            return false
        }
        let count = Int(readback.size)
        return Self.byteArray(readback.bytes, count: count) == Self.byteArray(expected, count: count)
    }

    // MARK: Apply (ControlCore -> SMC bridge)

    /// Maps `ControlCore`'s `ChargingCommand`s (SPEC §3.3) onto the two
    /// setters above. This is the only bridge between the pure control core
    /// and hardware writes — `decide(...)` itself never touches SMC.
    public func apply(_ commands: [ChargingCommand]) {
        for command in commands {
            switch command {
            case .allowCharging:
                setChargingInhibited(false)
            case .inhibitCharging:
                setChargingInhibited(true)
            case .enableAdapter:
                setAdapterDisabled(false)
            case .disableAdapter:
                setAdapterDisabled(true)
            }
        }
    }

    // MARK: Write helper — the ONLY call site of `writer.writeData` in this
    // type, and every caller above passes one of the five allowlisted key
    // string literals. There is no path from `apply`/the public setters to
    // an arbitrary caller-supplied key.

    private func write(key keyStr: String, bytes: SMCBytes) {
        try? writer.writeData(FourCharCode(fromString: keyStr), bytes: bytes)
    }

    // MARK: Byte helpers (SMCBytes is a fixed 32-tuple; no direct indexing)

    static func makeSMCBytes(_ array: [UInt8]) -> SMCBytes {
        var bytes: SMCBytes = smcBytesZero
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<min(array.count, 32) {
                raw[i] = array[i]
            }
        }
        return bytes
    }

    static func byteArray(_ bytes: SMCBytes, count: Int) -> [UInt8] {
        var result: [UInt8] = []
        withUnsafeBytes(of: bytes) { raw in
            for i in 0..<max(0, min(count, 32)) {
                result.append(raw[i])
            }
        }
        return result
    }
}
