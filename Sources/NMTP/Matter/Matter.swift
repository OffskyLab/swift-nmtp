//
//  Matter.swift
//

import Foundation

// NBLA
public let NMTPMagic: [UInt8] = [0x4E, 0x42, 0x4C, 0x41]

/// The unit transmitted between nodes in the NMTP protocol (NMT — Nebula Matter Transfer).
///
/// Structurally equivalent to what networking calls an "envelope": a fixed-length header
/// carrying routing metadata, followed by a serialized body. Named `Matter` because in
/// the Nebula metaphor, celestial bodies communicate by transferring matter — not just
/// wrapping messages in envelopes.
///
/// Header layout (27 bytes, fixed):
/// ```
/// Magic    [0..3]   = "NBLA"  (4 bytes)
/// Version  [4]      = UInt8   (1 byte)
/// Type     [5]      = UInt8   (1 byte)
/// Flags    [6]      = UInt8   (1 byte)
/// MsgID    [7..22]  = UUID    (16 bytes)
/// Length   [23..26] = UInt32  (4 bytes, big-endian)
/// Body     [27..]   = MessagePack encoded payload (variable)
/// ```
public struct Matter: Sendable {
    public static let headerSize = 27

    public let version: UInt8
    public let type: MatterType
    public let flags: UInt8
    public let matterID: UUID
    public let body: Data

    public init(type: MatterType, flags: UInt8 = 0, matterID: UUID = UUID(), body: Data) {
        self.version = 1
        self.type = type
        self.flags = flags
        self.matterID = matterID
        self.body = body
    }
}

// MARK: - Serialization

extension Matter {

    public func serialized() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerSize + body.count)
        bytes.append(contentsOf: NMTPMagic)
        bytes.append(version)
        bytes.append(type.rawValue)
        bytes.append(flags)
        bytes.append(contentsOf: matterID.bytes)
        bytes.append(contentsOf: UInt32(body.count).bytes())
        bytes.append(contentsOf: body)
        return bytes
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Matter.headerSize else {
            throw NMTPError.invalidMatter("Too short: \(bytes.count) bytes")
        }

        let magic = Array(bytes[0..<4])
        guard magic == NMTPMagic else {
            throw NMTPError.invalidMatter("Invalid magic bytes")
        }

        let version = bytes[4]

        guard let type = MatterType(rawValue: bytes[5]) else {
            throw NMTPError.invalidMatter("Unknown matter type: \(bytes[5])")
        }

        let flags = bytes[6]
        let matterID = try UUID(bytes: Array(bytes[7..<23]))
        let length = Int(UInt32(bytes: Array(bytes[23..<27])))

        guard bytes.count >= Matter.headerSize + length else {
            throw NMTPError.invalidMatter("Body length mismatch")
        }

        let body = Data(bytes[Matter.headerSize ..< Matter.headerSize + length])

        self.version = version
        self.type = type
        self.flags = flags
        self.matterID = matterID
        self.body = body
    }
}
