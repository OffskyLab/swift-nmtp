import Logging
import NIO

public final class NMTServer: Sendable {
    public let address: SocketAddress
    private let channel: Channel
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?

    internal init(address: SocketAddress, channel: Channel, ownedEventLoopGroup: MultiThreadedEventLoopGroup?) {
        self.address = address
        self.channel = channel
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }
}

// MARK: - Bind
extension NMTServer {
    public static func bind(
        on address: SocketAddress,
        handler: any NMTHandler,
        tls: (any TLSContext)? = nil,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTServer {
        let owned = eventLoopGroup == nil ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let channel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                if let tls {
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let tlsHandler = try await tls.makeServerHandler()
                        // Bridge EventLoopFuture<Void> into the async context.
                        try await channel.pipeline.addHandlers([
                            tlsHandler,
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                            NMTServerInboundHandler(handler: handler),
                        ]).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                        NMTServerInboundHandler(handler: handler),
                    ])
                }
            }
            .bind(to: address)
            .get()
        let boundAddress = channel.localAddress ?? address
        return NMTServer(address: boundAddress, channel: channel, ownedEventLoopGroup: owned)
    }
}

// MARK: - Listen / Stop
extension NMTServer {
    public func listen() async throws {
        try await channel.closeFuture.get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }

    public func stop() async throws {
        try await channel.close().get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }

    public func closeNow() {
        channel.close(promise: nil)
    }
}

// MARK: - Inbound Handler
private final class NMTServerInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter
    typealias OutboundOut = Matter
    private let handler: any NMTHandler
    private let logger = Logger(label: "nmtp.server")

    init(handler: any NMTHandler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let matter = unwrapInboundIn(data)
        let channel = context.channel
        Task {
            do {
                if let reply = try await handler.handle(matter: matter, channel: channel) {
                    channel.writeAndFlush(reply, promise: nil)
                }
            } catch {
                logger.error("handler error: \(error)")
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
