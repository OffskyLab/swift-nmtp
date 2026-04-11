import NIO
import NIOWebSocket

/// Bridges WebSocket frames ↔ raw `ByteBuffer`s in the NMT pipeline.
///
/// - Inbound:  `WebSocketFrame` (binary) → `ByteBuffer` (for `MatterDecoder`)
/// - Outbound: `ByteBuffer` → `WebSocketFrame` (binary, masked when `isClient == true`)
///
/// Non-binary frames (text, continuation, ping, pong, close) are silently
/// dropped on the inbound path — the NMT protocol layer has no use for them.
final class NMTWebSocketFrameHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private let isClient: Bool

    init(isClient: Bool) {
        self.isClient = isClient
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .binary else { return }
        let unmasked = frame.unmaskedData
        context.fireChannelRead(wrapInboundOut(unmasked))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let maskKey: WebSocketMaskingKey? = isClient ? .random() : nil
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: buffer)
        context.write(wrapOutboundOut(frame), promise: promise)
    }
}
