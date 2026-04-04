//
//  Matter+Coding.swift
//

import Foundation
import MessagePacker

// MARK: - Body Encoding

extension Matter {

    public static func make<T: Encodable>(
        type: MatterType,
        body: T,
        matterID: UUID = UUID(),
        flags: UInt8 = 0
    ) throws -> Matter {
        let data = try MessagePackEncoder().encode(body)
        return Matter(type: type, flags: flags, matterID: matterID, body: data)
    }

    /// Create a reply Matter that matches the request's matterID.
    public func reply<T: Encodable>(body: T) throws -> Matter {
        let data = try MessagePackEncoder().encode(body)
        return Matter(type: .reply, matterID: matterID, body: data)
    }
}

// MARK: - Body Decoding

extension Matter {

    public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        return try MessagePackDecoder().decode(type, from: body)
    }
}
