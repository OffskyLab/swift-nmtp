import Foundation

/// A type-identified, Codable message for use with `PeerDispatcher`.
///
/// Conforming types must provide a unique `messageType` (UInt16) that identifies
/// them on the wire. This value is encoded into the `MatterPayload.type` field.
public protocol PeerMessage: Codable, Sendable {
    /// Unique type identifier used in the wire payload.
    static var messageType: UInt16 { get }
    /// Instance bridge for existential use. Default implementation provided.
    var messageType: UInt16 { get }
}

extension PeerMessage {
    public var messageType: UInt16 { Self.messageType }
}
