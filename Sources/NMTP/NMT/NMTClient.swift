import Foundation
import NIO

public final class NMTClient: Sendable {
    public let targetAddress: SocketAddress
    public let pushes: AsyncStream<Matter>

    private let channel: Channel
    private let pendingRequests: PendingRequests
    private let pushContinuation: AsyncStream<Matter>.Continuation

    internal init(
        targetAddress: SocketAddress,
        channel: Channel,
        pendingRequests: PendingRequests,
        pushes: AsyncStream<Matter>,
        pushContinuation: AsyncStream<Matter>.Continuation
    ) {
        self.targetAddress = targetAddress
        self.channel = channel
        self.pendingRequests = pendingRequests
        self.pushes = pushes
        self.pushContinuation = pushContinuation
    }
}

// MARK: - Connect
extension NMTClient {
    public static func connect(
        to address: SocketAddress,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTClient {
        let elg = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let pendingRequests = PendingRequests()
        var cont: AsyncStream<Matter>.Continuation!
        let pushes = AsyncStream<Matter> { cont = $0 }
        let inboundHandler = NMTClientInboundHandler(pendingRequests: pendingRequests, pushContinuation: cont)
        let channel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    inboundHandler,
                ])
            }
            .connect(to: address)
            .get()
        return NMTClient(
            targetAddress: address,
            channel: channel,
            pendingRequests: pendingRequests,
            pushes: pushes,
            pushContinuation: cont
        )
    }
}

// MARK: - Send
extension NMTClient {
    public func fire(matter: Matter) {
        channel.writeAndFlush(matter, promise: nil)
    }

    public func request(matter: Matter) async throws -> Matter {
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.register(id: matter.matterID, continuation: continuation)
            channel.writeAndFlush(matter, promise: nil)
        }
    }

    public func close() async throws {
        try await channel.close().get()
    }
}

// MARK: - Inbound Handler
private final class NMTClientInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter
    private let pendingRequests: PendingRequests
    private let pushContinuation: AsyncStream<Matter>.Continuation

    init(pendingRequests: PendingRequests, pushContinuation: AsyncStream<Matter>.Continuation) {
        self.pendingRequests = pendingRequests
        self.pushContinuation = pushContinuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let matter = unwrapInboundIn(data)
        if !pendingRequests.fulfill(matter) {
            pushContinuation.yield(matter)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pendingRequests.failAll(error: NMTPError.connectionClosed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pendingRequests.failAll(error: error)
        context.close(promise: nil)
    }
}
