//
//  MatterPayload.swift
//

import Foundation

/// The structured envelope wrapping every Matter's payload.
///
/// NMTP defines the wire format of the envelope but never interprets the `type` value.
/// Class-2 protocols assign meaning to `type` and define the `body` format entirely.
///
/// Wire format: `[type: 2 bytes big-endian][body: remaining bytes]`
public struct MatterPayload: Sendable {
    /// Minimum payload size (just the 2-byte type field, empty body).
    public static let minSize = 2

    /// Class-2 dispatch key. `0x0000` = untyped. Value space owned by class-2 protocol.
    public let type: UInt16
    /// Application-defined content. Class-2 protocol owns the format entirely.
    public let body: Data

    public init(type: UInt16 = 0, body: Data = Data()) {
        self.type = type
        self.body = body
    }

    /// Serializes to `[type: 2 bytes big-endian][body]`.
    public var encoded: Data {
        var data = Data(capacity: Self.minSize + body.count)
        data.append(UInt8(type >> 8))
        data.append(UInt8(type & 0xFF))
        data.append(contentsOf: body)
        return data
    }

    /// Parses from raw `Data`. Throws `NMTPError.invalidMatter` if fewer than 2 bytes.
    public init(data: Data) throws {
        guard data.count >= Self.minSize else {
            throw NMTPError.invalidMatter("Payload too short for envelope: \(data.count) bytes")
        }
        self.type = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        self.body = data.dropFirst(Self.minSize)
    }
}
