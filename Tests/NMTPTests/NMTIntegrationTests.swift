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

/// Sends one unsolicited matter to the channel and returns nil (no direct reply).
private struct PushHandler: NMTHandler {
    let pushBody: Data

    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        let push = Matter(type: .reply, body: pushBody)
        channel.writeAndFlush(push, promise: nil)
        return nil
    }
}

// MARK: - Timeout tests

final class RequestTimeoutTests: XCTestCase {

    /// A server that accepts connections and decodes Matter, but never replies.
    private func makeSilentServer(elg: MultiThreadedEventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    // No reply handler — connection stays silent.
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func testRequestThrowsTimeoutWhenServerNeverReplies() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let server = try await makeSilentServer(elg: elg)
        let address = server.localAddress!
        let client = try await NMTClient.connect(to: address, eventLoopGroup: elg)

        let request = Matter(type: .call, body: Data("ping".utf8))
        do {
            _ = try await client.request(matter: request, timeout: .milliseconds(100))
            XCTFail("Expected NMTPError.timeout")
        } catch NMTPError.timeout {
            // Expected
        }

        try? await client.close()
        try? await server.close().get()
        try await elg.shutdownGracefully()
    }
}

// MARK: - PendingRequests unit tests

final class PendingRequestsTests: XCTestCase {

    /// register + fulfill from a concurrent Task returns the correct Matter.
    func testFulfillReturnsCorrectMatter() async throws {
        let pending = PendingRequests()
        let expected = Matter(type: .reply, body: Data("hello".utf8))

        let received: Matter = try await withCheckedThrowingContinuation { continuation in
            pending.register(id: expected.matterID, continuation: continuation)
            Task { pending.fulfill(expected) }
        }

        XCTAssertEqual(received.matterID, expected.matterID)
        XCTAssertEqual(received.body, Data("hello".utf8))
    }

    /// fulfill with an unknown UUID returns false and does not crash.
    func testFulfillUnknownIdReturnsFalse() {
        let pending = PendingRequests()
        let unknown = Matter(type: .call, body: Data())
        XCTAssertFalse(pending.fulfill(unknown))
    }

    /// failAll resumes every registered continuation with the given error.
    func testFailAllResumesAllContinuations() async throws {
        let pending = PendingRequests()
        let ids = (0..<5).map { _ in UUID() }

        await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        let _: Matter = try await withCheckedThrowingContinuation { cont in
                            pending.register(id: id, continuation: cont)
                        }
                        XCTFail("Expected connectionClosed error")
                    } catch let e as NMTPError {
                        XCTAssertEqual(e, NMTPError.connectionClosed)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            pending.failAll(error: NMTPError.connectionClosed)
        }
    }
}
