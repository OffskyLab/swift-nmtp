import Testing
import Foundation
@testable import NMTP

@Suite("Matter Tests")
struct MatterTests {

    struct Ping: Codable, Sendable, Equatable {
        var message: String
    }

    @Test("MatterType raw values spot check")
    func matterTypeRawValues() {
        #expect(MatterType.clone.rawValue == 0x01)
        #expect(MatterType.call.rawValue == 0x04)
        #expect(MatterType.reply.rawValue == 0x05)
        #expect(MatterType.register.rawValue == 0x02)
        #expect(MatterType.find.rawValue == 0x03)
    }

    @Test("Matter serialization round-trip")
    func matterSerializationRoundTrip() throws {
        let id = UUID()
        let bodyData = Data([0xAA, 0xBB, 0xCC])
        let matter = Matter(type: .call, flags: 0x01, matterID: id, body: bodyData)

        let bytes = matter.serialized()
        #expect(bytes.count == Matter.headerSize + bodyData.count)

        let recovered = try Matter(bytes: bytes)
        #expect(recovered.version == matter.version)
        #expect(recovered.type == matter.type)
        #expect(recovered.flags == matter.flags)
        #expect(recovered.matterID == matter.matterID)
        #expect(recovered.body == matter.body)
    }

    @Test("Matter too short throws NMTPError")
    func matterTooShortThrows() throws {
        let shortBytes: [UInt8] = [0x4E, 0x42, 0x4C, 0x41, 0x01]
        #expect(throws: NMTPError.self) {
            _ = try Matter(bytes: shortBytes)
        }
    }

    @Test("Matter invalid magic throws NMTPError")
    func matterInvalidMagicThrows() throws {
        // Create valid matter then corrupt the magic
        let matter = Matter(type: .call, body: Data([0x01]))
        var bytes = matter.serialized()
        bytes[0] = 0xFF  // corrupt magic
        #expect(throws: NMTPError.self) {
            _ = try Matter(bytes: bytes)
        }
    }

    @Test("Matter.make + decodeBody round-trip")
    func matterMakeDecodeRoundTrip() throws {
        let ping = Ping(message: "hello")
        let matter = try Matter.make(type: .call, body: ping)
        let decoded = try matter.decodeBody(Ping.self)
        #expect(decoded == ping)
    }

    @Test("Matter.reply preserves matterID")
    func matterReplyPreservesMatterID() throws {
        let ping = Ping(message: "hello")
        let request = try Matter.make(type: .call, body: ping)
        let replyBody = Ping(message: "pong")
        let reply = try request.reply(body: replyBody)
        #expect(reply.matterID == request.matterID)
        #expect(reply.type == .reply)
    }

    @Test("Matter headerSize is 27")
    func matterHeaderSize() {
        #expect(Matter.headerSize == 27)
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
