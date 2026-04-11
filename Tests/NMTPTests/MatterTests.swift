import Testing
import Foundation
@testable import NMTP

@Suite("Matter Tests")
struct MatterTests {

    @Test("Matter headerSize is 27")
    func matterHeaderSize() {
        #expect(Matter.headerSize == 27)
    }

    @Test("Matter serialization round-trip")
    func matterSerializationRoundTrip() throws {
        let id = UUID()
        let payload = Data([0xAA, 0xBB, 0xCC])
        let matter = Matter(behavior: .command, ttl: 0, matterID: id, payload: payload)

        let bytes = matter.serialized()
        #expect(bytes.count == Matter.headerSize + payload.count)

        let recovered = try Matter(bytes: bytes)
        #expect(recovered.version   == matter.version)
        #expect(recovered.behavior  == matter.behavior)
        #expect(recovered.ttl       == matter.ttl)
        #expect(recovered.matterID  == matter.matterID)
        #expect(recovered.payload   == matter.payload)
    }

    @Test("Matter TTL round-trips")
    func matterTTLRoundTrip() throws {
        let matter = Matter(behavior: .event, ttl: 7, payload: Data())
        let recovered = try Matter(bytes: matter.serialized())
        #expect(recovered.ttl == 7)
        #expect(recovered.behavior == .event)
    }

    @Test("Matter too short throws NMTPError")
    func matterTooShortThrows() {
        let shortBytes: [UInt8] = [0x4E, 0x42, 0x4C, 0x41, 0x01]
        #expect(throws: NMTPError.self) {
            _ = try Matter(bytes: shortBytes)
        }
    }

    @Test("Matter invalid magic throws NMTPError")
    func matterInvalidMagicThrows() throws {
        let matter = Matter(behavior: .command, payload: Data([0x01]))
        var bytes = matter.serialized()
        bytes[0] = 0xFF
        #expect(throws: NMTPError.self) {
            _ = try Matter(bytes: bytes)
        }
    }

    @Test("Matter unknown behavior throws NMTPError")
    func matterUnknownBehaviorThrows() throws {
        let matter = Matter(behavior: .command, payload: Data())
        var bytes = matter.serialized()
        bytes[6] = 0xFF   // behavior byte
        #expect(throws: NMTPError.self) {
            _ = try Matter(bytes: bytes)
        }
    }

    @Test("Matter.make builds payload envelope")
    func matterMakeBuildsEnvelope() throws {
        let body = Data("hello".utf8)
        let matter = Matter.make(behavior: .command, type: 0x0001, body: body)
        let envelope = try matter.decodePayload()
        #expect(envelope.type == 0x0001)
        #expect(envelope.body == body)
    }

    @Test("Matter.makeReply preserves matterID")
    func matterMakeReplyPreservesMatterID() {
        let request = Matter(behavior: .command, payload: Data([0x01]))
        let reply = request.makeReply(payload: Data([0x02]))
        #expect(reply.matterID == request.matterID)
        #expect(reply.behavior == .reply)
        #expect(reply.ttl == 0)
    }
}

@Suite("MatterBehavior Tests")
struct MatterBehaviorTests {

    @Test("MatterBehavior raw values")
    func behaviorRawValues() {
        #expect(MatterBehavior.heartbeat.rawValue == 0x00)
        #expect(MatterBehavior.command.rawValue  == 0x01)
        #expect(MatterBehavior.query.rawValue    == 0x02)
        #expect(MatterBehavior.event.rawValue    == 0x03)
        #expect(MatterBehavior.reply.rawValue    == 0x04)
    }

    @Test("MatterBehavior round-trips through UInt8")
    func behaviorRoundTrip() throws {
        for raw: UInt8 in 0x00...0x04 {
            let b = try #require(MatterBehavior(rawValue: raw))
            #expect(b.rawValue == raw)
        }
        #expect(MatterBehavior(rawValue: 0x05) == nil)
    }
}

@Suite("NMTPConstants Tests")
struct NMTPConstantsTests {

    @Test("NMTPConstants values")
    func nmtpConstantsValues() {
        #expect(NMTPConstants.maxEventTTL     == 15)
        #expect(NMTPConstants.defaultEventTTL == 7)
        #expect(NMTPConstants.defaultEventTTL < NMTPConstants.maxEventTTL)
    }
}

@Suite("MatterPayload Tests")
struct MatterPayloadTests {

    @Test("MatterPayload encodes type + body")
    func encodesTypeAndBody() {
        let body = Data([0xAA, 0xBB])
        let envelope = MatterPayload(type: 0x0042, body: body)
        let encoded = envelope.encoded

        #expect(encoded.count == 4)           // 2 type bytes + 2 body bytes
        #expect(encoded[0] == 0x00)           // high byte of 0x0042
        #expect(encoded[1] == 0x42)           // low byte of 0x0042
        #expect(encoded[2] == 0xAA)
        #expect(encoded[3] == 0xBB)
    }

    @Test("MatterPayload round-trips through Data")
    func roundTrip() throws {
        let original = MatterPayload(type: 0x0007, body: Data("hello".utf8))
        let recovered = try MatterPayload(data: original.encoded)
        #expect(recovered.type == original.type)
        #expect(recovered.body == original.body)
    }

    @Test("MatterPayload with zero type and empty body")
    func untyped() throws {
        let envelope = MatterPayload()
        let encoded = envelope.encoded
        #expect(encoded.count == 2)
        #expect(encoded[0] == 0x00)
        #expect(encoded[1] == 0x00)

        let recovered = try MatterPayload(data: encoded)
        #expect(recovered.type == 0)
        #expect(recovered.body.isEmpty)
    }

    @Test("MatterPayload init(data:) throws on too-short input")
    func tooShortThrows() {
        #expect(throws: NMTPError.self) {
            _ = try MatterPayload(data: Data([0x00]))
        }
    }
}
