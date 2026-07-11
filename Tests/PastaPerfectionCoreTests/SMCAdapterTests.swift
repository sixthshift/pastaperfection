import IOKit
import Testing
@testable import PastaPerfectionCore

/// Fake `SMCWriting` — no real IOKit involved. `addKey` controls which SPEC
/// §4 allowlist keys "exist" on this fake firmware (driving `probe()`'s
/// fallback choice); `writes` records every write in call order so tests can
/// assert byte-exactness and idempotence.
final class FakeSMC: SMCWriting {
    private struct KeyInfo {
        var type: FourCharCode
        var size: UInt32
    }

    private var existingKeys: [String: KeyInfo] = [:]
    private var lastWritten: [String: SMCBytes] = [:]

    private(set) var writes: [(key: String, bytes: [UInt8])] = []

    /// Override for what `readData` returns for a key, independent of what
    /// was last written — used to simulate a write whose readback doesn't
    /// match (verify-after-write failure).
    var readOverride: [String: SMCBytes] = [:]

    func addKey(_ key: String, size: UInt32) {
        existingKeys[key] = KeyInfo(type: FourCharCode(fromString: "ui32"), size: size)
    }

    func keyInformation(_ key: FourCharCode) throws -> (type: FourCharCode, size: UInt32)? {
        guard let info = existingKeys[key.toString()] else { return nil }
        return (type: info.type, size: info.size)
    }

    func readData(_ key: FourCharCode) throws -> (bytes: SMCBytes, type: FourCharCode, size: UInt32) {
        let keyStr = key.toString()
        guard let info = existingKeys[keyStr] else {
            throw SMC.SMCError.keyNotFound(code: keyStr)
        }
        let bytes = readOverride[keyStr] ?? lastWritten[keyStr] ?? smcBytesZero
        return (bytes: bytes, type: info.type, size: info.size)
    }

    func writeData(_ key: FourCharCode, bytes: SMCBytes) throws {
        let keyStr = key.toString()
        guard let info = existingKeys[keyStr] else {
            throw SMC.SMCError.keyNotFound(code: keyStr)
        }
        writes.append((key: keyStr, bytes: FakeSMC.byteArray(bytes, count: Int(info.size))))
        lastWritten[keyStr] = bytes
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

/// A steady, mid-charge, plugged-in, non-hot reading — the default fixture
/// for tests that don't care about the exact battery numbers.
private func idleBattery(isCharging: Bool) -> BatteryState {
    BatteryState(percent: 50, isCharging: isCharging, externalConnected: true, temperatureC: 25.0)
}

@Suite struct SMCAdapterTests {

    // MARK: Byte-exactness (CHTE)

    @Test func chteInhibitTrueWritesLittleEndianOne() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.setChargingInhibited(true)

        #expect(fake.writes.count == 1)
        #expect(fake.writes[0].key == "CHTE")
        #expect(fake.writes[0].bytes == [0x01, 0x00, 0x00, 0x00])
    }

    @Test func chteInhibitFalseWritesLittleEndianZeroContrast() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: true) })

        adapter.setChargingInhibited(false)

        #expect(fake.writes.count == 1)
        #expect(fake.writes[0].key == "CHTE")
        #expect(fake.writes[0].bytes == [0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Fallback (CH0B + CH0C when CHTE missing)

    @Test func fallbackWritesBothCH0BAndCH0CWhenCHTEMissing() {
        let fake = FakeSMC()
        fake.addKey("CH0B", size: 1)
        fake.addKey("CH0C", size: 1)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.setChargingInhibited(true)

        #expect(fake.writes.count == 2)
        #expect(fake.writes.contains { $0.key == "CH0B" && $0.bytes == [0x02] })
        #expect(fake.writes.contains { $0.key == "CH0C" && $0.bytes == [0x02] })
    }

    // MARK: Adapter (CHIE)

    @Test func adapterDisableWritesCHIE08() {
        let fake = FakeSMC()
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(true)

        #expect(fake.writes.count == 1)
        #expect(fake.writes[0].key == "CHIE")
        #expect(fake.writes[0].bytes == [0x08])
    }

    @Test func adapterEnableWritesCHIE00Contrast() {
        let fake = FakeSMC()
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(false)

        #expect(fake.writes.count == 1)
        #expect(fake.writes[0].key == "CHIE")
        #expect(fake.writes[0].bytes == [0x00])
    }

    @Test func adapterFallbackWritesCH0IWhenCHIEMissing() {
        let fake = FakeSMC()
        fake.addKey("CH0I", size: 1)
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(true)

        #expect(fake.writes.count == 1)
        #expect(fake.writes[0].key == "CH0I")
        #expect(fake.writes[0].bytes == [0x01])
    }

    // MARK: Idempotence

    @Test func repeatedSameStateInhibitCallWritesExactlyOnce() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.setChargingInhibited(true)
        adapter.setChargingInhibited(true)

        #expect(fake.writes.count == 1)
    }

    @Test func repeatedSameStateAdapterCallWritesExactlyOnce() {
        let fake = FakeSMC()
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(true)
        adapter.setAdapterDisabled(true)
        adapter.setAdapterDisabled(true)

        #expect(fake.writes.count == 1)
    }

    // MARK: Verify-after-write (charging inhibit, via injectable battery reader)

    @Test func verifyFailsWhenBatteryStillReportsChargingAfterInhibit() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: true) })

        adapter.setChargingInhibited(true)

        #expect(adapter.lastWriteVerified == false)
    }

    @Test func verifySucceedsWhenBatteryReportsNotChargingAfterInhibitContrast() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.setChargingInhibited(true)

        #expect(adapter.lastWriteVerified == true)
    }

    // MARK: Verify-after-write (adapter, via readback of the key itself)

    @Test func adapterWriteVerifiedTrueWhenReadbackMatches() {
        let fake = FakeSMC()
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(true)

        #expect(adapter.lastWriteVerified == true)
    }

    @Test func adapterWriteVerifiedFalseWhenReadbackMismatches() {
        let fake = FakeSMC()
        fake.addKey("CHIE", size: 1)
        // Firmware canary: readback disagrees with what will be written
        // (0x08 disabled) — simulates a write that silently had no effect.
        fake.readOverride["CHIE"] = SMCAdapter.makeSMCBytes([0x00])
        let adapter = SMCAdapter(writer: fake)

        adapter.setAdapterDisabled(true)

        #expect(adapter.lastWriteVerified == false)
    }

    // MARK: apply() bridges ControlCore commands to the two setters

    @Test func applyMapsChargingCommandsToTheCorrectSetters() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.apply([.inhibitCharging, .disableAdapter])

        #expect(fake.writes.contains { $0.key == "CHTE" && $0.bytes == [0x01, 0x00, 0x00, 0x00] })
        #expect(fake.writes.contains { $0.key == "CHIE" && $0.bytes == [0x08] })
    }

    @Test func applyMapsAllowAndEnableCommandsContrast() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        fake.addKey("CHIE", size: 1)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: true) })

        adapter.apply([.allowCharging, .enableAdapter])

        #expect(fake.writes.contains { $0.key == "CHTE" && $0.bytes == [0x00, 0x00, 0x00, 0x00] })
        #expect(fake.writes.contains { $0.key == "CHIE" && $0.bytes == [0x00] })
    }

    // MARK: Probe caching + fallback selection

    @Test func probeSelectsFallbackKeysWhenPrimaryKeysMissing() {
        let fake = FakeSMC()
        fake.addKey("CH0B", size: 1)
        fake.addKey("CH0C", size: 1)
        fake.addKey("CH0I", size: 1)
        let adapter = SMCAdapter(writer: fake)

        let caps = adapter.probe()

        #expect(caps.inhibitKey == .ch0bCh0c)
        #expect(caps.adapterKey == .ch0i)
    }

    @Test func probeSelectsPrimaryKeysWhenPresent() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        fake.addKey("CHIE", size: 1)
        fake.addKey("CH0B", size: 1) // present too, but CHTE wins per fallback order
        fake.addKey("CH0C", size: 1)
        let adapter = SMCAdapter(writer: fake)

        let caps = adapter.probe()

        #expect(caps.inhibitKey == .chte)
        #expect(caps.adapterKey == .chie)
    }

    // MARK: Allowlist — SMCAdapter's public surface is exactly probe/apply
    // plus the two setters. There is no generic `write(key:bytes:)` (or
    // similar) entry point in the public API: every write in this file
    // originates from one of the five hardcoded key-string literals inside
    // `setChargingInhibited`/`setAdapterDisabled` (SPEC §4) — verified here
    // by exercising the full public surface and confirming only allowlisted
    // keys ever appear on the wire, plus by inspection of SMCAdapter.swift.
    @Test func onlyAllowlistedKeysAppearAcrossTheEntirePublicSurface() {
        let fake = FakeSMC()
        fake.addKey("CHTE", size: 4)
        fake.addKey("CH0B", size: 1)
        fake.addKey("CH0C", size: 1)
        fake.addKey("CHIE", size: 1)
        fake.addKey("CH0I", size: 1)
        let adapter = SMCAdapter(writer: fake, readBattery: { idleBattery(isCharging: false) })

        adapter.apply([.inhibitCharging, .allowCharging, .disableAdapter, .enableAdapter])

        let allowlist: Set<String> = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I"]
        #expect(fake.writes.allSatisfy { allowlist.contains($0.key) })
    }
}
