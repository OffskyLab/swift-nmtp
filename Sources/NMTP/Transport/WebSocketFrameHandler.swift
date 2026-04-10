import NIO
import NIOWebSocket

/// Bridges WebSocket frames ↔ raw ByteBuffers in the NMT pipeline.
///
/// - Inbound:  `WebSocketFrame` (binary) → `ByteBuffer` (for `MatterDecoder`)
/// - Outbound: `ByteBuffer` → `WebSocketFrame` (binary, masked when `isClient == true`)
///
/// Control frames (ping, pong, close) are silently dropped on the inbound path
/// because the NMT protocol layer has no use for them.
final class NMTWebSocketFrameHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private let isClient: Bool

    init(isClient: Bool) {
        self.isClient = isClient
    }

    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .binary else { return }
        // Use the computed property which automatically unmasks if a masking key is present.
        let unmasked = frame.unmaskedData
        context.fireChannelRead(wrapInboundOut(unmasked))
    }

    // MARK: Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        // Client frames MUST be masked with a fresh random key (RFC 6455 §5.3).
        let maskKey: WebSocketMaskingKey? = isClient ? .random() : nil
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: buffer)
        context.write(wrapOutboundOut(frame), promise: promise)
    }
}
