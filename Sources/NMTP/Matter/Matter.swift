//
//  Matter.swift
//

import Foundation

// NBLA
public let NMTPMagic: [UInt8] = [0x4E, 0x42, 0x4C, 0x41]

/// The unit transmitted between nodes in the NMTP protocol (NMT — Nebula Matter Transfer).
///
/// Header layout (27 bytes, fixed):
/// ```
/// Magic    [0..3]   = "NBLA"  (4 bytes)
/// Version  [4]      = UInt8   (1 byte)
/// TTL      [5]      = UInt8   (1 byte) — Event ripple hop count; 0x00 for others
/// Behavior [6]      = UInt8   (1 byte) — see MatterBehavior
/// MatterID [7..22]  = UUID    (16 bytes)
/// Length   [23..26] = UInt32  (4 bytes, big-endian)
/// Payload  [27..]   = [Type:2 bytes][Body:N bytes] — see MatterPayload
/// ```
public struct Matter: Sendable {
    public static let headerSize = 27

    public let version: UInt8
    public let behavior: MatterBehavior
    public let ttl: UInt8
    public let matterID: UUID
    public let payload: Data

    public init(
        behavior: MatterBehavior,
        ttl: UInt8 = 0,
        matterID: UUID = UUID(),
        payload: Data = Data()
    ) {
        self.version = 1
        self.behavior = behavior
        self.ttl = ttl
        self.matterID = matterID
        self.payload = payload
    }
}

// MARK: - Serialization

extension Matter {

    public func serialized() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerSize + payload.count)
        bytes.append(contentsOf: NMTPMagic)
        bytes.append(version)
        bytes.append(ttl)
        bytes.append(behavior.rawValue)
        bytes.append(contentsOf: matterID.bytes)
        bytes.append(contentsOf: UInt32(payload.count).bytes())
        bytes.append(contentsOf: payload)
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
        let ttl = bytes[5]

        guard let behavior = MatterBehavior(rawValue: bytes[6]) else {
            throw NMTPError.invalidMatter("Unknown behavior: \(bytes[6])")
        }

        let matterID = try UUID(bytes: Array(bytes[7..<23]))
        let length = Int(try UInt32(bytes: Array(bytes[23..<27])))

        guard bytes.count >= Matter.headerSize + length else {
            throw NMTPError.invalidMatter("Payload length mismatch")
        }

        let payload = Data(bytes[Matter.headerSize ..< Matter.headerSize + length])

        self.version = version
        self.ttl = ttl
        self.behavior = behavior
        self.matterID = matterID
        self.payload = payload
    }
}
