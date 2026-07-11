import IOKit
import Testing
@testable import PastaPerfectionCore

/// Pure struct/encoding tests for the SMC client (SPEC §4). No SMC writes,
/// no hardware access, no root required — these only exercise FourCharCode
/// conversion and SMCParamStruct construction.
@Suite struct SMCTests {

    // MARK: FourCharCode conversion

    @Test func fourCharCodeFromKnownStrings() {
        #expect(FourCharCode(fromString: "CHTE") == 0x43485445)
        #expect(FourCharCode(fromString: "CH0B") == 0x43483042)
    }

    @Test func fourCharCodeRoundTripsThroughToString() {
        #expect(FourCharCode(fromString: "CHTE").toString() == "CHTE")
        #expect(FourCharCode(fromString: "CH0B").toString() == "CH0B")
        #expect(FourCharCode(fromString: "CH0C").toString() == "CH0C")
        #expect(FourCharCode(fromString: "CHIE").toString() == "CHIE")
        #expect(FourCharCode(fromString: "CH0I").toString() == "CH0I")
    }

    // MARK: SMCParamStruct layout

    @Test func paramStructIs80Bytes() {
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
    }

    // MARK: Param struct construction (pure — no IOKit call)

    @Test func keyInfoParamStructSetsKeyAndSelector() {
        let key = FourCharCode(fromString: "CHTE")
        let s = SMC.keyInfoParamStruct(key: key)

        #expect(s.key == key)
        #expect(s.data8 == SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue)
        // A pure probe carries no payload size yet.
        #expect(s.keyInfo.dataSize == 0)
    }

    @Test func readDataParamStructSetsKeyAndDataSize() {
        let key = FourCharCode(fromString: "CHTE")
        let s = SMC.readDataParamStruct(key: key, size: 4)

        #expect(s.key == key)
        #expect(s.data8 == SMCParamStruct.Selector.kSMCReadKey.rawValue)
        #expect(s.keyInfo.dataSize == 4)
        // Read requests carry no outbound payload bytes.
        #expect(s.bytes.0 == 0)
    }

    @Test func writeDataParamStructSetsKeyDataSizeAndBytes() {
        let key = FourCharCode(fromString: "CH0B")
        let payload: SMCBytes = (0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let s = SMC.writeDataParamStruct(key: key, bytes: payload, size: 1)

        #expect(s.key == key)
        #expect(s.data8 == SMCParamStruct.Selector.kSMCWriteKey.rawValue)
        #expect(s.keyInfo.dataSize == 1)
        #expect(s.bytes.0 == 0x02)
    }

    @Test func readAndWriteParamStructsUseDifferentSelectorBytes() {
        let key = FourCharCode(fromString: "CHTE")
        let readStruct = SMC.readDataParamStruct(key: key, size: 4)
        let writeStruct = SMC.writeDataParamStruct(key: key, bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                                                    size: 4)

        #expect(readStruct.data8 != writeStruct.data8)
        #expect(readStruct.data8 == SMCParamStruct.Selector.kSMCReadKey.rawValue)
        #expect(writeStruct.data8 == SMCParamStruct.Selector.kSMCWriteKey.rawValue)
        // Both target the same key.
        #expect(readStruct.key == writeStruct.key)
    }

    // MARK: Result/Selector enum sanity (used to interpret driver responses)

    @Test func selectorRawValuesMatchIOKitContract() {
        #expect(SMCParamStruct.Selector.kSMCHandleYPCEvent.rawValue == 2)
        #expect(SMCParamStruct.Selector.kSMCReadKey.rawValue == 5)
        #expect(SMCParamStruct.Selector.kSMCWriteKey.rawValue == 6)
        #expect(SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue == 8)
        #expect(SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue == 9)
    }

    @Test func resultRawValuesMatchIOKitContract() {
        #expect(SMCParamStruct.Result.kSMCSuccess.rawValue == 0)
        #expect(SMCParamStruct.Result.kSMCError.rawValue == 1)
        #expect(SMCParamStruct.Result.kSMCKeyNotFound.rawValue == 132)
    }
}
