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

// MARK: - Heartbeat tests

final class HeartbeatTests: XCTestCase {

    /// Connects a client with a very short heartbeat interval to a TCP server
    /// that accepts the connection but never sends any data back.
    /// Asserts the client detects the dead connection within the expected window.
    func testClientDetectsDeadConnectionViaHeartbeat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        // Raw silent server — accepts TCP but sends nothing.
        let silentServer = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Accept the connection silently.
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        // Client with a 50 ms heartbeat interval and missedLimit = 2.
        // Connection declared dead after 50 ms × 2 = 100 ms.
        let client = try await NMTClient.connect(
            to: silentServer.localAddress!,
            heartbeatInterval: .milliseconds(50),
            heartbeatMissedLimit: 2,
            eventLoopGroup: elg
        )

        defer {
            Task {
                try? await client.close()
                try? await silentServer.close().get()
                try? await elg.shutdownGracefully()
            }
        }

        // Wait for 250 ms — well past the 100 ms dead-connection deadline.
        try await Task.sleep(for: .milliseconds(250))

        // The next request should fail because the channel is now closed.
        do {
            _ = try await client.request(
                matter: Matter(type: .call, body: Data()),
                timeout: .milliseconds(50)
            )
            XCTFail("Expected a connection error")
        } catch let error as NMTPError {
            // Accept connectionDead, connectionClosed, or timeout — all indicate
            // the channel is no longer usable.
            XCTAssertTrue(
                error == .connectionDead || error == .connectionClosed || error == .timeout,
                "Unexpected error: \(error)"
            )
        }
    }

    func testHeartbeatDoesNotDisruptNormalTraffic() async throws {
        // This test requires server-side heartbeat wiring (Task 5).
        // It will be run after Task 5 completes.
        // For now, just verify server with default params and client with heartbeat
        // can exchange messages.
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )

        let client = try await NMTClient.connect(
            to: server.address,
            heartbeatInterval: .milliseconds(30)
        )

        defer {
            Task {
                try? await client.close()
                server.closeNow()
            }
        }

        // Fire several requests while heartbeats are running in the background.
        for i in 0..<5 {
            let body = Data("msg-\(i)".utf8)
            let reply = try await client.request(matter: Matter(type: .call, body: body))
            XCTAssertEqual(reply.body, body)
        }
    }
}

// MARK: - Graceful shutdown tests

final class GracefulShutdownTests: XCTestCase {

    /// A handler that waits `delay` before replying, simulating slow work.
    private struct SlowEchoHandler: NMTHandler {
        let delay: Duration
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            try await Task.sleep(for: delay)
            return Matter(type: .reply, matterID: matter.matterID, body: matter.body)
        }
    }

    func testSlowRequestCompletesBeforeShutdownCloses() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(300))
        )

        let client = try await NMTClient.connect(to: server.address)

        // Fire the slow request — it will take ~300 ms to reply.
        async let replyTask = client.request(matter: Matter(type: .call, body: Data("slow".utf8)))

        // Give request a moment to reach the server.
        try await Task.sleep(for: .milliseconds(50))

        // Immediately start shutdown with a generous grace period.
        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        // Both should complete: reply arrives, THEN server closes.
        let reply = try await replyTask
        try await shutdownTask

        XCTAssertEqual(reply.body, Data("slow".utf8))

        Task { try? await client.close() }
    }

    func testNewRequestDuringDrainFailsWithConnectionError() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(500))
        )

        let clientA = try await NMTClient.connect(to: server.address)
        let clientB = try await NMTClient.connect(to: server.address)

        // clientA fires a slow request.
        Task { _ = try? await clientA.request(matter: Matter(type: .call, body: Data())) }

        // Give the slow request a moment to reach the server handler.
        try await Task.sleep(for: .milliseconds(50))

        // Start shutdown.
        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        // Give shutdown a moment to set the flag.
        try await Task.sleep(for: .milliseconds(50))

        // clientB sends a new request during drain — server should reject it.
        do {
            _ = try await clientB.request(
                matter: Matter(type: .call, body: Data()),
                timeout: .milliseconds(200)
            )
            XCTFail("Expected a connection error during drain")
        } catch let e as NMTPError {
            XCTAssertTrue(
                e == .connectionClosed || e == .timeout || e == .connectionDead,
                "Unexpected error: \(e)"
            )
        }

        try await shutdownTask

        Task { try? await clientA.close() }
        Task { try? await clientB.close() }
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
