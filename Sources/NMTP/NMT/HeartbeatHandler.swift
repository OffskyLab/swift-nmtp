import Foundation
import NIO
import NIOExtras

/// NIO channel handler that detects dead connections via application-layer heartbeats.
///
/// Place this handler immediately after `IdleStateHandler` in the pipeline:
/// ```
/// IdleStateHandler → HeartbeatHandler → NMTInboundHandler
/// ```
///
/// When the reader is idle for `heartbeatInterval`, `IdleStateHandler` fires
/// `IdleStateHandler.IdleStateEvent.read`. `HeartbeatHandler` responds by sending
/// a `Matter(type: .heartbeat)` and incrementing `missedBeats`. If `missedBeats`
/// reaches `missedLimit`, the channel is closed with `NMTPError.connectionDead`.
///
/// Any received data (heartbeat reply or regular matter) resets `missedBeats`.
/// Received heartbeats are answered with a heartbeat reply and are **not** forwarded
/// to the next handler, keeping the business layer unaware of the mechanism.
///
/// All mutable state is accessed only from the channel's event loop thread, which
/// is why `@unchecked Sendable` is safe here.
final class HeartbeatHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn  = Matter
    typealias InboundOut = Matter
    typealias OutboundIn = Matter
    typealias OutboundOut = Matter

    private let missedLimit: Int
    private var missedBeats = 0

    init(missedLimit: Int) {
        self.missedLimit = missedLimit
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        missedBeats = 0                          // any received data = connection is alive
        let matter = unwrapInboundIn(data)
        if matter.type == .heartbeat {
            // Reply to keep the other side's idle timer alive; don't forward.
            let reply = Matter(type: .heartbeat, body: Data())
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        missedBeats += 1
        guard missedBeats < missedLimit else {
            // Declare the connection dead.
            context.fireErrorCaught(NMTPError.connectionDead)
            context.close(promise: nil)
            return
        }
        // Send a heartbeat probe.
        let probe = Matter(type: .heartbeat, body: Data())
        context.writeAndFlush(wrapOutboundOut(probe), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
