// Tests/NMTPTests/TestHelpers.swift
// Shared test helpers for the NMTPTests target.
import NIO
@testable import NMTP

/// Echoes each incoming matter back as a `.reply` with the same matterID and body.
struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(type: .reply, matterID: matter.matterID, body: matter.body)
    }
}
