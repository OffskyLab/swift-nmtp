import NIO

public final class NMTClient: Sendable {
    public let targetAddress: SocketAddress
    public let pushes: AsyncStream<Matter>

    private let channel: Channel
    private let pendingRequests: PendingRequests
    private let pushContinuation: AsyncStream<Matter>.Continuation
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?

    internal init(
        targetAddress: SocketAddress,
        channel: Channel,
        pendingRequests: PendingRequests,
        pushes: AsyncStream<Matter>,
        pushContinuation: AsyncStream<Matter>.Continuation,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    ) {
        self.targetAddress = targetAddress
        self.channel = channel
        self.pendingRequests = pendingRequests
        self.pushes = pushes
        self.pushContinuation = pushContinuation
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }
}

// MARK: - Connect
extension NMTClient {
    public static func connect(
        to address: SocketAddress,
        tls: (any TLSContext)? = nil,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTClient {
        let owned = eventLoopGroup == nil
            ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let pendingRequests = PendingRequests()
        var cont: AsyncStream<Matter>.Continuation!
        let pushes = AsyncStream<Matter> { cont = $0 }
        let inboundHandler = NMTClientInboundHandler(pendingRequests: pendingRequests, pushContinuation: cont)
        do {
            let channel = try await ClientBootstrap(group: elg)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    if let tls {
                        let promise = channel.eventLoop.makePromise(of: Void.self)
                        promise.completeWithTask {
                            // SNI requires a hostname, not a raw IP — pass nil when only an IP is available.
                            let tlsHandler = try await tls.makeClientHandler(serverHostname: nil)
                            // Bridge EventLoopFuture<Void> into the async context.
                            try await channel.pipeline.addHandlers([
                                tlsHandler,
                                ByteToMessageHandler(MatterDecoder()),
                                MessageToByteHandler(MatterEncoder()),
                                inboundHandler,
                            ]).get()
                        }
                        return promise.futureResult
                    } else {
                        return channel.pipeline.addHandlers([
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                            inboundHandler,
                        ])
                    }
                }
                .connect(to: address)
                .get()
            return NMTClient(
                targetAddress: address,
                channel: channel,
                pendingRequests: pendingRequests,
                pushes: pushes,
                pushContinuation: cont,
                ownedEventLoopGroup: owned
            )
        } catch {
            try? await owned?.shutdownGracefully()
            throw error
        }
    }
}

// MARK: - Send
extension NMTClient {
    public func fire(matter: Matter) {
        channel.writeAndFlush(matter, promise: nil)
    }

    public func request(matter: Matter, timeout: Duration = .seconds(30)) async throws -> Matter {
        return try await withThrowingTaskGroup(of: Matter.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.pendingRequests.register(id: matter.matterID, continuation: continuation)
                        self.channel.writeAndFlush(matter, promise: nil)
                    }
                } onCancel: {
                    // Remove the pending UUID so no memory leak occurs.
                    self.pendingRequests.fail(id: matter.matterID, error: NMTPError.timeout)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NMTPError.timeout
            }
            guard let result = try await group.next() else {
                preconditionFailure("Task group unexpectedly empty — both tasks were added above")
            }
            group.cancelAll()
            return result
        }
    }

    public func close() async throws {
        try await channel.close().get()
        try await ownedEventLoopGroup?.shutdownGracefully()
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
