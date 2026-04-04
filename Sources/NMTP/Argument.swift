//
//  Argument.swift
//

import Foundation
import MessagePacker

public struct Argument: Sendable {
    public internal(set) var key: String
    public internal(set) var data: Data

    public init(key: String, data: Data) {
        self.key = key
        self.data = data
    }
}

// MARK: - Encoding

extension Argument {

    public static func wrap<T: Encodable>(key: String, value: T) throws -> Argument {
        let data = try MessagePackEncoder().encode(value)
        return Argument(key: key, data: data)
    }

    public func unwrap<T: Decodable>(as type: T.Type) throws -> T {
        return try MessagePackDecoder().decode(type, from: data)
    }
}

// MARK: - Array Helpers

extension Array where Element == Argument {

    public func toDictionary() -> [String: Any?] {
        return Dictionary(uniqueKeysWithValues: self.compactMap { arg in
            guard let value = try? arg.unwrap(as: AnyDecodable.self) else { return nil }
            return (arg.key, value.value)
        })
    }

    public func toEncoded() -> [EncodedArgument] {
        return self.map { EncodedArgument(key: $0.key, value: $0.data) }
    }
}

extension Array where Element == EncodedArgument {

    public func toArguments() -> [Argument] {
        return self.map { Argument(key: $0.key, data: $0.value) }
    }
}

// MARK: - AnyDecodable Helper

private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self)  { value = v; return }
        if let v = try? container.decode(Int.self)     { value = v; return }
        if let v = try? container.decode(Double.self)  { value = v; return }
        if let v = try? container.decode(Bool.self)    { value = v; return }
        value = ""
    }
}
