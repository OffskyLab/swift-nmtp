import XCTest
import NIO
import NIOWebSocket
@testable import NMTP

final class NMTTransportTests: XCTestCase {

    func testDefaultCaseIsTCP() {
        if case .tcp = NMTTransport.tcp { } else {
            XCTFail("Expected .tcp")
        }
    }

    func testWebSocketDefaultPath() {
        if case .webSocket(let path) = NMTTransport.webSocket() {
            XCTAssertEqual(path, "/nmt")
        } else {
            XCTFail("Expected .webSocket")
        }
    }

    func testWebSocketCustomPath() {
        if case .webSocket(let path) = NMTTransport.webSocket(path: "/custom") {
            XCTAssertEqual(path, "/custom")
        } else {
            XCTFail("Expected .webSocket")
        }
    }
}

// MARK: - NMTWebSocketFrameHandler unit tests

final class WebSocketFrameHandlerTests: XCTestCase {

    // Binary frame payload must be forwarded downstream as a plain ByteBuffer.
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

    // Non-binary frames (ping, text, …) must be silently dropped.
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

    // Server-side outbound ByteBuffer → unmasked binary WebSocketFrame.
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

    // Client-side outbound ByteBuffer → masked binary WebSocketFrame (RFC 6455 §5.3).
    func testOutbound_client_writesMaskedBinaryFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: true)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        XCTAssertNoThrow(try channel.writeOutbound(buf))

        let frame = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertNotNil(frame.maskKey, "Client frames MUST be masked (RFC 6455 §5.3)")
        // Verify the payload survives the mask/unmask round-trip.
        // In EmbeddedChannel the WebSocket encoder has not run yet, so frame.data
        // holds the original plain bytes and frame.maskKey records the key that
        // the encoder *will* use.  Applying unmaskedData here would XOR plain
        // data a second time and corrupt it, so we read frame.data directly.
        var payload = frame.data
        XCTAssertEqual(payload.readString(length: 5), "hello")
    }

    // Masked inbound frame (client → server): handler must unmask before forwarding.
    func testInbound_maskedFrame_unmasksPayload() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        let original: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        // WebSocketMaskingKey init takes a Collection<UInt8>, not a tuple.
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

    /// Successful connect + close implies the HTTP→WebSocket upgrade was accepted.
    func testWebSocket_serverAcceptsUpgrade() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: .webSocket()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: .webSocket())
        try await client.close()
    }

    /// Matter request-reply must work end-to-end over WebSocket.
    func testWebSocket_requestReply() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: .webSocket()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: .webSocket())
        defer { Task { try await client.close() } }

        let sentBody = Data("hello-ws".utf8)
        let request = Matter(type: .call, body: sentBody)
        let reply = try await client.request(matter: request)

        XCTAssertEqual(reply.matterID, request.matterID)
        XCTAssertEqual(reply.type, .reply)
        XCTAssertEqual(reply.body, sentBody)
    }

    /// Server-initiated push must arrive at the client over WebSocket.
    func testWebSocket_serverPush() async throws {
        let pushBody = Data("push-ws".utf8)
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: PushHandler(pushBody: pushBody),
            transport: .webSocket()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: .webSocket())
        defer { Task { try await client.close() } }

        client.fire(matter: Matter(type: .call, body: Data()))

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
        XCTAssertEqual(received?.body, pushBody)
    }

    /// Default transport must still be TCP — regression guard.
    func testWebSocket_tcpDefault() async throws {
        // No transport: argument — defaults to .tcp
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let sentBody = Data("tcp-default".utf8)
        let reply = try await client.request(matter: Matter(type: .call, body: sentBody))
        XCTAssertEqual(reply.body, sentBody)
    }

    /// TLS + WebSocket must complete an echo round-trip.
    func testWebSocket_withTLS() async throws {
        let tls = MockTLSContext()

        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            tls: tls,
            transport: .webSocket()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(
            to: server.address,
            tls: tls,
            transport: .webSocket()
        )
        defer { Task { try await client.close() } }

        let sentBody = Data("tls-ws".utf8)
        let reply = try await client.request(matter: Matter(type: .call, body: sentBody))
        XCTAssertEqual(reply.body, sentBody)
    }
}
