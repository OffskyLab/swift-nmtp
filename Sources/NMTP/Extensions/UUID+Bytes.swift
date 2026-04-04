//
//  UUID+Bytes.swift
//

import Foundation

// MARK: - UUID

extension UUID {

    public var bytes: [UInt8] {
        var uuid = self.uuid
        let ptr = UnsafeBufferPointer(start: &uuid.0, count: MemoryLayout.size(ofValue: uuid))
        return .init(ptr)
    }

    public var data: Data {
        return .init(bytes)
    }

    public init(bytes: ArraySlice<UInt8>) throws {
        try self.init(bytes: [UInt8](bytes))
    }

    public init(data: Data) throws {
        try self.init(bytes: data.map { $0 })
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw NMTPError.fail(message: "UUID bytes length should be 16 bytes.")
        }

        let bytesTuple = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        self.init(uuid: bytesTuple)
    }
}

// MARK: - Integer Bytes

extension FixedWidthInteger {
    public func bytes() -> [UInt8] {
        return withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}

extension UInt32 {
    public init(bytes: [UInt8]) {
        assert(bytes.count == 4)
        self = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    }
}
