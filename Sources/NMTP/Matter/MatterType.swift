//
//  MatterType.swift
//

import Foundation

public enum MatterType: UInt8, Sendable {
    case clone      = 0x01
    case register   = 0x02
    case find       = 0x03
    case call       = 0x04
    case reply      = 0x05
    case activate   = 0x06
    case heartbeat  = 0x07
    case unregister = 0x08
    case enqueue    = 0x09
    case ack        = 0x0a
    case subscribe  = 0x0b
    case unsubscribe = 0x0c
    case event       = 0x0d
    case findGalaxy  = 0x0e
}
