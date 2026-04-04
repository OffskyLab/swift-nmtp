import Testing
import Foundation
@testable import NMTP

@Suite("NMTPError Tests")
struct NMTPErrorTests {

    @Test("NMTPError cases are throwable")
    func errorCasesThrowable() throws {
        #expect(throws: NMTPError.self) {
            throw NMTPError.fail(message: "test failure")
        }
        #expect(throws: NMTPError.self) {
            throw NMTPError.invalidMatter("bad header")
        }
        #expect(throws: NMTPError.self) {
            throw NMTPError.notConnected
        }
        #expect(throws: NMTPError.self) {
            throw NMTPError.connectionClosed
        }
    }

    @Test("UUID round-trip via bytes")
    func uuidRoundTrip() throws {
        let original = UUID()
        let bytes = original.bytes
        #expect(bytes.count == 16)
        let recovered = try UUID(bytes: bytes)
        #expect(recovered == original)
    }

    @Test("UUID round-trip via Data")
    func uuidRoundTripData() throws {
        let original = UUID()
        let data = original.data
        let recovered = try UUID(data: data)
        #expect(recovered == original)
    }

    @Test("UUID init with wrong byte count throws NMTPError")
    func uuidWrongByteCountThrows() throws {
        #expect(throws: NMTPError.self) {
            _ = try UUID(bytes: [0x00, 0x01, 0x02])
        }
    }

    @Test("UInt32 bytes round-trip")
    func uint32BytesRoundTrip() throws {
        let value: UInt32 = 0xDEADBEEF
        let bytes = value.bytes()
        #expect(bytes.count == 4)
        let recovered = try UInt32(bytes: bytes)
        #expect(recovered == value)
    }

    @Test("UInt32 big-endian byte order")
    func uint32BigEndian() throws {
        let value: UInt32 = 0x01020304
        let bytes = value.bytes()
        #expect(bytes == [0x01, 0x02, 0x03, 0x04])
    }

    @Test("UInt32 init with wrong byte count throws NMTPError")
    func uint32WrongByteCountThrows() throws {
        #expect(throws: NMTPError.self) {
            _ = try UInt32(bytes: [0x01, 0x02])
        }
    }
}
