//
//  MatterBehavior.swift
//

/// Behavior classification carried in every Matter header (byte[6]).
///
/// NMTP uses this field to determine routing and propagation rules.
/// The class-2 type (what *kind* of command/query/event) lives in the
/// first 2 bytes of the payload, not here.
public enum MatterBehavior: UInt8, Sendable {
    /// NMTP-internal: heartbeat probe/reply. Never forwarded to application layer.
    case heartbeat = 0x00
    /// Requires something to happen. Has a target. Expects a Reply.
    case command   = 0x01
    /// Asks about state. Has a target. Expects a Reply.
    case query     = 0x02
    /// Records that something happened. No target. Propagates via TTL.
    case event     = 0x03
    /// Returns a result to the sender of a Command or Query.
    case reply     = 0x04
}

/// Protocol-level constants for NMTP.
public enum NMTPConstants {
    /// Nodes MUST drop incoming Events whose TTL exceeds this value.
    public static let maxEventTTL: UInt8 = 15
    /// Recommended initial TTL for outgoing Events.
    public static let defaultEventTTL: UInt8 = 7
}
