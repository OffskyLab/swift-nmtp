// Tests/NMTPTests/TLSContextTests.swift
import XCTest
import NIO
import Synchronization
@testable import NMTP

final class TLSContextTests: XCTestCase {

    private static let asyncPipelineSettleDelay: UInt64 = 100_000_000  // 100 ms

    // MARK: - Helpers

    /// A TLSContext that installs a no-op handler and records how many times it was called.
    private final class MockTLSContext: TLSContext, Sendable {
        private let _serverCalls = Mutex<Int>(0)
        private let _clientCalls = Mutex<Int>(0)

        var serverCallCount: Int { _serverCalls.withLock { $0 } }
        var clientCallCount: Int { _clientCalls.withLock { $0 } }

        func makeServerHandler() async throws -> any ChannelHandler {
            _serverCalls.withLock { $0 += 1 }
            return PassThroughHandler()
        }

        func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler {
            _clientCalls.withLock { $0 += 1 }
            return PassThroughHandler()
        }
    }

    /// Passes all inbound bytes downstream unchanged.
    private final class PassThroughHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireChannelRead(data)
        }
    }

    // MARK: - Tests

    /// bind(tls: nil) works identically to before (no regression).
    func testBind_withNilTLS_worksAsPlainServer() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            tls: nil
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, tls: nil)
        defer { Task { try? await client.close() } }

        let matter = Matter(behavior: .command, payload: Data("ping".utf8))
        let reply = try await client.request(matter: matter)
        XCTAssertEqual(reply.matterID, matter.matterID)
    }

    /// bind(tls: mock) calls makeServerHandler() when a client connects.
    func testBind_withTLSContext_callsMakeServerHandler() async throws {
        let mockTLS = MockTLSContext()
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            tls: mockTLS
        )
        defer { server.closeNow() }

        // Open a raw TCP connection to trigger childChannelInitializer.
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let rawChannel = try await ClientBootstrap(group: elg)
            .connect(to: server.address).get()
        rawChannel.close(promise: nil)

        // Allow the async initializer to complete.
        try await Task.sleep(nanoseconds: Self.asyncPipelineSettleDelay)

        XCTAssertEqual(mockTLS.serverCallCount, 1)
        try await elg.shutdownGracefully()
    }

    /// connect(tls: mock) calls makeClientHandler() during bootstrap.
    func testConnect_withTLSContext_callsMakeClientHandler() async throws {
        // Plain server — we only care that the client's channelInitializer ran.
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )
        defer { server.closeNow() }

        let mockTLS = MockTLSContext()
        // The connect may fail because the PassThroughHandler corrupts NMT framing —
        // that is expected and acceptable here; we only need the initializer to run.
        do {
            _ = try await NMTClient.connect(to: server.address, tls: mockTLS)
        } catch {
            // Expected: NMT framing error after PassThroughHandler corrupts the pipeline.
        }

        try await Task.sleep(nanoseconds: Self.asyncPipelineSettleDelay)
        XCTAssertEqual(mockTLS.clientCallCount, 1)
    }
}
