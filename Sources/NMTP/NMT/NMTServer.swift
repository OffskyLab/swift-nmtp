import Logging
import NIO
import Synchronization

// MARK: - ServerState

/// Tracks the number of currently-executing `NMTHandler.handle()` calls.
/// Thread-safe via a single `Mutex`-protected struct.
/// Created once per server instance; shared across all child-channel handlers.
final class ServerState: Sendable {
    private struct Box {
        var inflightCount = 0
        var isShuttingDown = false
        var drainContinuation: CheckedContinuation<Void, Never>?
    }
    private let box = Mutex<Box>(Box())

    var isShuttingDown: Bool { box.withLock { $0.isShuttingDown } }

    func beginShutdown() { box.withLock { $0.isShuttingDown = true } }

    func incrementInflight() { box.withLock { $0.inflightCount += 1 } }

    func decrementInflight() {
        box.withLock { b in
            b.inflightCount -= 1
            if b.inflightCount == 0, let cont = b.drainContinuation {
                b.drainContinuation = nil
                cont.resume()
            }
        }
    }

    /// Suspends until all in-flight handler calls complete, then returns.
    func drain() async {
        await withCheckedContinuation { continuation in
            box.withLock { b in
                if b.inflightCount == 0 {
                    continuation.resume()
                } else {
                    b.drainContinuation = continuation
                }
            }
        }
    }
}

// MARK: - NMTServer

public final class NMTServer: Sendable {
    public let address: SocketAddress
    private let channel: Channel
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    private let serverState: ServerState

    internal init(
        address: SocketAddress,
        channel: Channel,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?,
        serverState: ServerState
    ) {
        self.address = address
        self.channel = channel
        self.ownedEventLoopGroup = ownedEventLoopGroup
        self.serverState = serverState
    }
}

// MARK: - Bind

extension NMTServer {
    public static func bind(
        on address: SocketAddress,
        handler: any NMTHandler,
        tls: (any TLSContext)? = nil,
        transport: NMTTransport = .tcp,   // ← new param, ignored until Task 4
        heartbeatInterval: Duration = .seconds(30),
        heartbeatMissedLimit: Int = 2,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTServer {
        let owned = eventLoopGroup == nil ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let serverState = ServerState()
        let channel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let serverHandler = NMTServerInboundHandler(handler: handler, serverState: serverState)
                if let tls {
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let tlsHandler = try await tls.makeServerHandler()
                        try await channel.pipeline.addHandlers([
                            tlsHandler,
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                            IdleStateHandler(readTimeout: heartbeatInterval.timeAmount),
                            HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                            serverHandler,
                        ]).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                        IdleStateHandler(readTimeout: heartbeatInterval.timeAmount),
                        HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                        serverHandler,
                    ])
                }
            }
            .bind(to: address)
            .get()
        let boundAddress = channel.localAddress ?? address
        return NMTServer(
            address: boundAddress,
            channel: channel,
            ownedEventLoopGroup: owned,
            serverState: serverState
        )
    }
}

// MARK: - Listen / Stop / Shutdown

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

    /// Gracefully stops the server:
    /// 1. Stops accepting new connections.
    /// 2. Waits up to `gracePeriod` for all in-flight `NMTHandler.handle()` calls to complete.
    /// 3. Shuts down the event loop group (closing all remaining channels).
    public func shutdown(gracePeriod: Duration = .seconds(30)) async {
        serverState.beginShutdown()
        // Stop accepting new connections (child channels remain open for draining).
        try? await channel.close().get()
        // Drain with a deadline: whichever finishes first (drain or sleep) wins.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.serverState.drain() }
            group.addTask { try? await Task.sleep(for: gracePeriod) }
            await group.next()
            group.cancelAll()
        }
        try? await ownedEventLoopGroup?.shutdownGracefully()
    }
}

// MARK: - Server-side Inbound Handler

private final class NMTServerInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter
    typealias OutboundOut = Matter
    private let handler: any NMTHandler
    private let serverState: ServerState
    private let logger = Logger(label: "nmtp.server")

    init(handler: any NMTHandler, serverState: ServerState) {
        self.handler = handler
        self.serverState = serverState
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // During drain, reject new requests by closing the child channel.
        // The client's channelInactive fires, failing pending requests with .connectionClosed.
        if serverState.isShuttingDown {
            context.close(promise: nil)
            return
        }
        let matter = unwrapInboundIn(data)
        let channel = context.channel
        serverState.incrementInflight()
        Task {
            defer { serverState.decrementInflight() }
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
