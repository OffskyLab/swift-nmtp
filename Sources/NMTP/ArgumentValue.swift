//
//  ArgumentValue.swift
//

import Foundation

/// A JSON-compatible argument value.
/// Supports strings, integers, doubles, booleans, and arrays of those types.
public enum ArgumentValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ArgumentValue])
}

// MARK: - Literal Expressibility

extension ArgumentValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ArgumentValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension ArgumentValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension ArgumentValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ArgumentValue: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = ArgumentValue
    public init(arrayLiteral elements: ArgumentValue...) { self = .array(elements) }
}

// MARK: - Encodable

extension ArgumentValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .array(let v):  try container.encode(v)
        }
    }
}

// MARK: - Init from JSON-parsed Any

extension ArgumentValue {
    /// Initialise from a value returned by `JSONSerialization`.
    /// Bool must be checked before Int due to ObjC bridge.
    init(_ value: Any) {
        if let v = value as? Bool   { self = .bool(v);                       return }
        if let v = value as? Int    { self = .int(v);                        return }
        if let v = value as? Double { self = .double(v);                     return }
        if let v = value as? String { self = .string(v);                     return }
        if let v = value as? [Any]  { self = .array(v.map { .init($0) });    return }
        self = .string(String(describing: value))
    }
}
