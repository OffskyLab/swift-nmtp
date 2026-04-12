// Sources/NMTP/Matter/MatterPayload.swift

import Foundation

/// The structured envelope wrapping every Matter's payload.
///
/// Wire format: `[typeID: 2 bytes big-endian][body: remaining bytes]`
public struct MatterPayload: Sendable {
    public static let minSize = 2

    /// Class-2 dispatch key. `0x0000` = untyped. Value space owned by class-2 protocol.
    public let typeID: UInt16
    /// Application-defined content. Class-2 protocol owns the format entirely.
    public let body: Data

    public init(typeID: UInt16 = 0, body: Data = Data()) {
        self.typeID = typeID
        self.body = body
    }

    public var encoded: Data {
        var data = Data(capacity: Self.minSize + body.count)
        data.append(UInt8(typeID >> 8))
        data.append(UInt8(typeID & 0xFF))
        data.append(contentsOf: body)
        return data
    }

    public init(data: Data) throws {
        guard data.count >= Self.minSize else {
            throw NMTPError.invalidMatter("Payload too short for envelope: \(data.count) bytes")
        }
        self.typeID = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        self.body = data.dropFirst(Self.minSize)
    }
}
