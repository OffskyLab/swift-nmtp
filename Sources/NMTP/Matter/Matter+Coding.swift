//
//  Matter+Coding.swift
//

import Foundation

extension Matter {

    /// Creates a Matter with a standard payload envelope (`[type: 2 bytes][body]`).
    public static func make(
        behavior: MatterBehavior,
        type: UInt16 = 0,
        ttl: UInt8 = 0,
        body: Data = Data(),
        matterID: UUID = UUID()
    ) -> Matter {
        let envelope = MatterPayload(type: type, body: body)
        return Matter(behavior: behavior, ttl: ttl, matterID: matterID, payload: envelope.encoded)
    }

    /// Creates a Reply Matter matching this Matter's matterID.
    public func makeReply(payload: Data = Data()) -> Matter {
        Matter(behavior: .reply, ttl: 0, matterID: matterID, payload: payload)
    }

    /// Parses this Matter's payload as a `MatterPayload` envelope.
    public func decodePayload() throws -> MatterPayload {
        try MatterPayload(data: payload)
    }
}
