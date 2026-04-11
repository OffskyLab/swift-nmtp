import XCTest
import NIO
@testable import NMTP

final class NMTIntegrationTests: XCTestCase {

    func testRequestReplyRoundTrip() async throws {
        let server = try await NMTServer.bind(on: .makeAddressResolvingHost("127.0.0.1", port: 0), handler: EchoHandler())
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let sentPayload = Data("hello".utf8)
        let request = Matter(behavior: .command, payload: sentPayload)
        let reply = try await client.request(matter: request)

        XCTAssertEqual(reply.matterID, request.matterID)
        XCTAssertEqual(reply.behavior, MatterBehavior.reply)
        XCTAssertEqual(reply.payload, sentPayload)
    }

    func testPushStreamReceivesUnsolicitedMatter() async throws {
        let pushBody = Data("push-payload".utf8)
        let pushHandler = PushHandler(pushBody: pushBody)

        let server = try await NMTServer.bind(on: .makeAddressResolvingHost("127.0.0.1", port: 0), handler: pushHandler)
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let trigger = Matter(behavior: .command, payload: Data())
        client.fire(matter: trigger)

        var received: Matter?
        received = try await withThrowingTaskGroup(of: Matter?.self) { group in
            group.addTask {
                for await matter in client.pushes { return matter }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.payload, pushBody)
    }
}

// MARK: - Timeout tests

final class RequestTimeoutTests: XCTestCase {

    private func makeSilentServer(elg: MultiThreadedEventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
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

        let request = Matter(behavior: .command, payload: Data("ping".utf8))
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

    func testClientDetectsDeadConnectionViaHeartbeat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let silentServer = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let client = try await NMTClient.connect(
            to: silentServer.localAddress!,
            transport: TCPTransport(heartbeatInterval: .milliseconds(50), missedLimit: 2),
            eventLoopGroup: elg
        )

        defer {
            Task {
                try? await client.close()
                try? await silentServer.close().get()
                try? await elg.shutdownGracefully()
            }
        }

        try await Task.sleep(for: .milliseconds(250))

        do {
            _ = try await client.request(
                matter: Matter(behavior: .command, payload: Data()),
                timeout: .milliseconds(50)
            )
            XCTFail("Expected a connection error")
        } catch let error as NMTPError {
            XCTAssertTrue(
                error == .connectionDead || error == .connectionClosed || error == .timeout,
                "Unexpected error: \(error)"
            )
        }
    }

    func testHeartbeatDoesNotDisruptNormalTraffic() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )

        let client = try await NMTClient.connect(
            to: server.address,
            transport: TCPTransport(heartbeatInterval: .milliseconds(30))
        )

        defer {
            Task {
                try? await client.close()
                server.closeNow()
            }
        }

        for i in 0..<5 {
            let body = Data("msg-\(i)".utf8)
            let reply = try await client.request(matter: Matter(behavior: .command, payload: body))
            XCTAssertEqual(reply.payload, body)
        }
    }
}

// MARK: - Graceful shutdown tests

final class GracefulShutdownTests: XCTestCase {

    private struct SlowEchoHandler: NMTHandler {
        let delay: Duration
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            try await Task.sleep(for: delay)
            return Matter(behavior: .reply, matterID: matter.matterID, payload: matter.payload)
        }
    }

    func testSlowRequestCompletesBeforeShutdownCloses() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(300))
        )

        let client = try await NMTClient.connect(to: server.address)

        async let replyTask = client.request(matter: Matter(behavior: .command, payload: Data("slow".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        let reply = try await replyTask
        try await shutdownTask

        XCTAssertEqual(reply.payload, Data("slow".utf8))

        Task { try? await client.close() }
    }

    func testNewRequestDuringDrainFailsWithConnectionError() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(500))
        )

        let clientA = try await NMTClient.connect(to: server.address)
        let clientB = try await NMTClient.connect(to: server.address)

        Task { _ = try? await clientA.request(matter: Matter(behavior: .command, payload: Data())) }

        try await Task.sleep(for: .milliseconds(50))

        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        try await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await clientB.request(
                matter: Matter(behavior: .command, payload: Data()),
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

    func testFulfillReturnsCorrectMatter() async throws {
        let pending = PendingRequests()
        let expected = Matter(behavior: .reply, payload: Data("hello".utf8))

        let received: Matter = try await withCheckedThrowingContinuation { continuation in
            pending.register(id: expected.matterID, continuation: continuation)
            Task { pending.fulfill(expected) }
        }

        XCTAssertEqual(received.matterID, expected.matterID)
        XCTAssertEqual(received.payload, Data("hello".utf8))
    }

    func testFulfillUnknownIdReturnsFalse() {
        let pending = PendingRequests()
        let unknown = Matter(behavior: .command, payload: Data())
        XCTAssertFalse(pending.fulfill(unknown))
    }

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
