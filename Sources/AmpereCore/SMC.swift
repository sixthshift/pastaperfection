//
// SMC.swift
// AmpereCore
//
// Ported from SMCKit (bclm-SMC.swift), trimmed to a generic key
// read/write/probe client. Fan and temperature convenience APIs were
// dropped — not needed by Ampere. The 80-byte SMCParamStruct layout and
// the IOConnectCallStructMethod selector-2 (kSMCHandleYPCEvent) plumbing
// are preserved intact (SPEC §4).
//
// This client enforces NO policy about which keys may be read or written.
// It is intentionally generic: allowlist enforcement for writes belongs to
// a higher layer (SPEC §4 — CHTE, CH0B, CH0C, CHIE, CH0I only), not here.
//
// Original file: docs/reference/bclm-SMC.swift
//
// The MIT License
//
// Copyright (C) 2014-2017  beltex <https://beltex.github.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import IOKit
import Foundation

//------------------------------------------------------------------------------
// MARK: FourCharCode conversion
//------------------------------------------------------------------------------

// `FourCharCode` is `UInt32` (defined by IOKit). SMC keys are always exactly
// 4 ASCII characters (e.g. "CHTE", "CH0B") packed big-endian into a UInt32.
// http://stackoverflow.com/a/22383661
public extension FourCharCode {

    /// Build a FourCharCode from a 4-character ASCII string, e.g. "CHTE".
    init(fromString str: String) {
        precondition(str.utf8.count == 4, "FourCharCode string must be exactly 4 ASCII bytes")

        self = str.utf8.reduce(0) { sum, byte in
            sum << 8 | UInt32(byte)
        }
    }

    /// Decode a FourCharCode back into its 4-character ASCII string.
    func toString() -> String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}

//------------------------------------------------------------------------------
// MARK: Bytes tuple
//------------------------------------------------------------------------------

/// The 32-byte fixed data buffer inside `SMCParamStruct`. C arrays bridge as
/// tuples in Swift.
public typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8)

/// All-zero `SMCBytes`, used as the default/empty buffer.
let smcBytesZero: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

//------------------------------------------------------------------------------
// MARK: Defined by AppleSMC.kext
//------------------------------------------------------------------------------

/// Defined by AppleSMC.kext.
///
/// This is the predefined struct that must be passed to communicate with the
/// AppleSMC driver. While the driver is closed source, the definition of this
/// struct happened to appear in the Apple PowerManagement project at around
/// version 211, and soon after disappeared. It can be seen in the PrivateLib.c
/// file under pmconfigd. Given that it is C code, this is the closest
/// translation to Swift from a type perspective.
///
/// ### Issues
///
/// * Padding for struct alignment when passed over to C side
/// * Size of struct must be 80 bytes
/// * C arrays are bridged as tuples
///
/// http://www.opensource.apple.com/source/PowerManagement/PowerManagement-211/
public struct SMCParamStruct {

    /// I/O Kit function selector.
    public enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }

    /// Return codes for `SMCParamStruct.result`.
    public enum Result: UInt8 {
        case kSMCSuccess     = 0
        case kSMCError       = 1
        case kSMCKeyNotFound = 132
    }

    public struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    public struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    public struct SMCKeyInfoData {
        /// How many bytes are written to `SMCParamStruct.bytes`.
        var dataSize: UInt32 = 0

        /// Type of data written to `SMCParamStruct.bytes`. This lets us know
        /// how to interpret it (translate it to human readable).
        var dataType: UInt32 = 0

        var dataAttributes: UInt8 = 0
    }

    /// FourCharCode telling the SMC what we want.
    public var key: UInt32 = 0

    public var vers = SMCVersion()

    public var pLimitData = SMCPLimitData()

    public var keyInfo = SMCKeyInfoData()

    /// Padding for struct alignment when passed over to the C side.
    public var padding: UInt16 = 0

    /// Result of an operation.
    public var result: UInt8 = 0

    public var status: UInt8 = 0

    /// Method selector.
    public var data8: UInt8 = 0

    public var data32: UInt32 = 0

    /// Data sent to / returned from the SMC.
    public var bytes: SMCBytes = smcBytesZero

    public init() {}
}

//------------------------------------------------------------------------------
// MARK: SMC Client
//------------------------------------------------------------------------------

/// Generic Apple System Management Controller (SMC) IOKit user-space client.
///
/// Works by talking to the `AppleSMC` IOService (the closed-source SMC
/// driver) via `IOConnectCallStructMethod` selector 2
/// (`kSMCHandleYPCEvent`), passing the 80-byte `SMCParamStruct`.
///
/// This type has no knowledge of any specific key's meaning, and enforces no
/// write allowlist — it is a thin, generic transport. Policy (which keys may
/// be written, and with what values) belongs to a higher layer per SPEC §4.
public final class SMC {

    public enum SMCError: Error, Equatable {
        /// AppleSMC IOService not found.
        case driverNotFound

        /// Failed to open a connection to the AppleSMC driver.
        case failedToOpen

        /// This SMC key is not valid on this machine.
        case keyNotFound(code: String)

        /// Requires root privileges.
        case notPrivileged

        /// https://developer.apple.com/library/mac/qa/qa1075/_index.html
        ///
        /// - parameter kIOReturn: I/O Kit error code
        /// - parameter smcResult: SMC-specific return code
        case unknown(kIOReturn: Int32, smcResult: UInt8)
    }

    /// Connection to the SMC driver. 0 when not open.
    private var connection: io_connect_t = 0

    public init() {}

    /// Open a connection to the AppleSMC driver. Must be called before any
    /// read/write/probe call.
    public func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSMC"))

        if service == 0 { throw SMCError.driverNotFound }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        if result != kIOReturnSuccess { throw SMCError.failedToOpen }
    }

    /// Close the connection to the SMC driver.
    @discardableResult
    public func close() -> Bool {
        let result = IOServiceClose(connection)
        connection = 0
        return result == kIOReturnSuccess
    }

    /// Get information about a key: its 4-char data type code and byte size.
    ///
    /// Returns `nil` if the key does not exist on this machine's firmware
    /// (this is expected/normal, not an error — e.g. probing `CHTE` on a
    /// pre-Tahoe machine). Any other failure (not privileged, driver error,
    /// no open connection) still throws.
    public func keyInformation(_ key: FourCharCode) throws -> (type: FourCharCode, size: UInt32)? {
        var input = SMC.keyInfoParamStruct(key: key)

        do {
            let output = try callDriver(&input)
            return (type: output.keyInfo.dataType, size: output.keyInfo.dataSize)
        } catch SMCError.keyNotFound {
            return nil
        }
    }

    /// Read the raw bytes of a key, along with its type and declared size.
    ///
    /// Throws `SMCError.keyNotFound` if the key does not exist.
    public func readData(_ key: FourCharCode) throws -> (bytes: SMCBytes, type: FourCharCode, size: UInt32) {
        guard let info = try keyInformation(key) else {
            throw SMCError.keyNotFound(code: key.toString())
        }

        var input = SMC.readDataParamStruct(key: key, size: info.size)
        let output = try callDriver(&input)

        return (bytes: output.bytes, type: info.type, size: info.size)
    }

    /// Write `bytes` to a key. The key's declared size (probed via
    /// `keyInformation`) determines how many bytes the SMC will treat as
    /// significant.
    ///
    /// Throws `SMCError.keyNotFound` if the key does not exist.
    ///
    /// NOTE: this client has no allowlist of its own — callers (SPEC §4) are
    /// responsible for restricting which keys are ever passed here.
    public func writeData(_ key: FourCharCode, bytes: SMCBytes) throws {
        guard let info = try keyInformation(key) else {
            throw SMCError.keyNotFound(code: key.toString())
        }

        var input = SMC.writeDataParamStruct(key: key, bytes: bytes, size: info.size)
        _ = try callDriver(&input)
    }

    /// Make an actual call to the SMC driver via `IOConnectCallStructMethod`.
    private func callDriver(
        _ input: inout SMCParamStruct,
        selector: SMCParamStruct.Selector = .kSMCHandleYPCEvent
    ) throws -> SMCParamStruct {
        assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct size must be 80 bytes")

        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(connection,
                                                UInt32(selector.rawValue),
                                                &input,
                                                inputSize,
                                                &output,
                                                &outputSize)

        switch (result, output.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCSuccess.rawValue):
            return output
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCKeyNotFound.rawValue):
            throw SMCError.keyNotFound(code: input.key.toString())
        case (kIOReturnNotPrivileged, _):
            throw SMCError.notPrivileged
        default:
            throw SMCError.unknown(kIOReturn: result, smcResult: output.result)
        }
    }
}

//------------------------------------------------------------------------------
// MARK: Param struct construction (pure — no IOKit call, unit-testable)
//------------------------------------------------------------------------------

extension SMC {

    /// Build the input `SMCParamStruct` for a `kSMCGetKeyInfo` probe.
    static func keyInfoParamStruct(key: FourCharCode) -> SMCParamStruct {
        var s = SMCParamStruct()
        s.key = key
        s.data8 = SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue
        return s
    }

    /// Build the input `SMCParamStruct` for a `kSMCReadKey` call.
    static func readDataParamStruct(key: FourCharCode, size: UInt32) -> SMCParamStruct {
        var s = SMCParamStruct()
        s.key = key
        s.keyInfo.dataSize = size
        s.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        return s
    }

    /// Build the input `SMCParamStruct` for a `kSMCWriteKey` call.
    static func writeDataParamStruct(key: FourCharCode, bytes: SMCBytes, size: UInt32) -> SMCParamStruct {
        var s = SMCParamStruct()
        s.key = key
        s.bytes = bytes
        s.keyInfo.dataSize = size
        s.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        return s
    }
}
