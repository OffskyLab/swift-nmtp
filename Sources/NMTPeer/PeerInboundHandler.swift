import NIO
import NMTP

/// Internal channel handler shared by Peer.connect and PeerListener-accepted channels.
/// Routes inbound Matters to PendingRequests (replies) or the incoming continuation (unsolicited).
final class PeerInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter

    private let pendingRequests: PendingRequests
    private let incomingContinuation: AsyncStream<Matter>.Continuation

    init(
        pendingRequests: PendingRequests,
        incomingContinuation: AsyncStream<Matter>.Continuation
    ) {
        self.pendingRequests = pendingRequests
        self.incomingContinuation = incomingContinuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let matter = unwrapInboundIn(data)
        if !pendingRequests.fulfill(matter) {
            incomingContinuation.yield(matter)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pendingRequests.failAll(error: NMTPError.connectionClosed)
        incomingContinuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pendingRequests.failAll(error: error)
        context.close(promise: nil)
    }
}
