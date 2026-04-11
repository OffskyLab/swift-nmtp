import XCTest
import NIO
import NIOWebSocket
@testable import NMTPWebSocket
import NMTP

// MARK: - Frame handler unit tests

final class WebSocketFrameHandlerTests: XCTestCase {

    func testInbound_binaryFrame_extractsPayload() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        var received = try XCTUnwrap(channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(received.readString(length: 5), "hello")
    }

    func testInbound_nonBinaryFrame_dropsFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 4)
        buf.writeString("ping")
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        let received = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertNil(received, "Non-binary frames must not reach the NMT layer")
    }

    func testOutbound_server_writesUnmaskedBinaryFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        XCTAssertNoThrow(try channel.writeOutbound(buf))

        let frame = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertTrue(frame.fin)
        XCTAssertNil(frame.maskKey, "Server frames must NOT be masked (RFC 6455 §5.3)")
    }

    func testOutbound_client_writesMaskedBinaryFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: true)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        XCTAssertNoThrow(try channel.writeOutbound(buf))

        let frame = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertNotNil(frame.maskKey, "Client frames MUST be masked (RFC 6455 §5.3)")
        // In EmbeddedChannel the WS encoder has not run yet, so frame.data holds
        // plain bytes and maskKey records the key the encoder *will* apply.
        var payload = frame.data
        XCTAssertEqual(payload.readString(length: 5), "hello")
    }

    func testInbound_maskedFrame_unmasksPayload() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        let original: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let keyArray: [UInt8] = [0xAB, 0xCD, 0xEF, 0x12]
        let key = try XCTUnwrap(WebSocketMaskingKey(keyArray))
        let maskedBytes = original.enumerated().map { i, b in b ^ keyArray[i % 4] }
        var maskedBuf = channel.allocator.buffer(capacity: original.count)
        maskedBuf.writeBytes(maskedBytes)

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: key, data: maskedBuf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        var received = try XCTUnwrap(channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(received.readBytes(length: original.count), original)
    }
}

// MARK: - WebSocket integration tests

final class WebSocketIntegrationTests: XCTestCase {

    private struct EchoHandler: NMTHandler {
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            Matter(behavior: .reply, matterID: matter.matterID, payload: matter.payload)
        }
    }

    private struct PushHandler: NMTHandler {
        let pushBody: Data
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            channel.writeAndFlush(Matter(behavior: .reply, payload: pushBody), promise: nil)
            return nil
        }
    }

    private final class MockTLSContext: TLSContext, Sendable {
        func makeServerHandler() async throws -> any ChannelHandler { PassThroughHandler() }
        func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler { PassThroughHandler() }
    }

    private final class PassThroughHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireChannelRead(data)
        }
    }

    func testWebSocket_serverAcceptsUpgrade() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        try await client.close()
    }

    func testWebSocket_requestReply() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        defer { Task { try await client.close() } }

        let sentBody = Data("hello-ws".utf8)
        let request = Matter(behavior: .command, payload: sentBody)
        let reply = try await client.request(matter: request)

        XCTAssertEqual(reply.matterID, request.matterID)
        XCTAssertEqual(reply.behavior, .reply)
        XCTAssertEqual(reply.payload, sentBody)
    }

    func testWebSocket_serverPush() async throws {
        let pushBody = Data("push-ws".utf8)
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: PushHandler(pushBody: pushBody),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        defer { Task { try await client.close() } }

        client.fire(matter: Matter(behavior: .command, payload: Data()))

        let received: Matter? = try await withThrowingTaskGroup(of: Matter?.self) { group in
            group.addTask {
                for await matter in client.pushes { return matter }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        XCTAssertNotNil(received)
        XCTAssertEqual(received?.payload, pushBody)
    }

    func testWebSocket_withTLS() async throws {
        let tls = MockTLSContext()

        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            tls: tls,
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(
            to: server.address,
            tls: tls,
            transport: WebSocketTransport()
        )
        defer { Task { try await client.close() } }

        let sentBody = Data("tls-ws".utf8)
        let reply = try await client.request(matter: Matter(behavior: .command, payload: sentBody))
        XCTAssertEqual(reply.payload, sentBody)
    }

    func testDefaultTransportIsTCP() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let sentBody = Data("tcp-default".utf8)
        let reply = try await client.request(matter: Matter(behavior: .command, payload: sentBody))
        XCTAssertEqual(reply.payload, sentBody)
    }
}
