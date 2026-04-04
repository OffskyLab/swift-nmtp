import XCTest
import NIO
@testable import NMTP

final class NMTIntegrationTests: XCTestCase {

    // MARK: - Echo round-trip

    func testRequestReplyRoundTrip() async throws {
        let server = try await NMTServer.bind(on: .makeAddressResolvingHost("127.0.0.1", port: 0), handler: EchoHandler())
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let sentBody = Data("hello".utf8)
        let request = Matter(type: .call, body: sentBody)
        let reply = try await client.request(matter: request)

        XCTAssertEqual(reply.matterID, request.matterID)
        XCTAssertEqual(reply.type, MatterType.reply)
        XCTAssertEqual(reply.body, sentBody)
    }

    // MARK: - Push stream (unsolicited server → client)

    func testPushStreamReceivesUnsolicitedMatter() async throws {
        let pushBody = Data("push-payload".utf8)
        let pushHandler = PushHandler(pushBody: pushBody)

        let server = try await NMTServer.bind(on: .makeAddressResolvingHost("127.0.0.1", port: 0), handler: pushHandler)
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        // Trigger the push by sending any matter; the handler ignores the request
        // and sends an unsolicited matter instead of replying.
        let trigger = Matter(type: .call, body: Data())
        client.fire(matter: trigger)

        var received: Matter?
        for await matter in client.pushes {
            received = matter
            break
        }

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.body, pushBody)
    }
}

// MARK: - Helpers

/// Returns the incoming matter as a .reply with the same matterID and body.
private struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(type: .reply, matterID: matter.matterID, body: matter.body)
    }
}

/// Sends one unsolicited matter to the channel and returns nil (no direct reply).
private struct PushHandler: NMTHandler {
    let pushBody: Data

    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        let push = Matter(type: .reply, body: pushBody)
        channel.writeAndFlush(push, promise: nil)
        return nil
    }
}
