// Sources/NMTP/Matter/Matter+Coding.swift

import Foundation

extension Matter {

    /// Creates a Matter with a standard payload envelope (`[typeID: 2 bytes][body]`).
    public static func make(
        type: MatterType,
        typeID: UInt16 = 0,
        ttl: UInt8 = 0,
        body: Data = Data(),
        matterID: UUID = UUID()
    ) -> Matter {
        let envelope = MatterPayload(type: typeID, body: body)
        return Matter(type: type, ttl: ttl, matterID: matterID, payload: envelope.encoded)
    }

    /// Creates a Reply Matter matching this Matter's matterID.
    public func makeReply(payload: Data = Data()) -> Matter {
        Matter(type: .reply, ttl: 0, matterID: matterID, payload: payload)
    }

    /// Parses this Matter's payload as a `MatterPayload` envelope.
    public func decodePayload() throws -> MatterPayload {
        try MatterPayload(data: payload)
    }
}
