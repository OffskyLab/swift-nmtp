import Foundation
import NIO

/// A handler that processes incoming Matter and optionally returns a reply.
public protocol NMTHandler: Sendable {
    func handle(matter: Matter, channel: Channel) async throws -> Matter?
}
