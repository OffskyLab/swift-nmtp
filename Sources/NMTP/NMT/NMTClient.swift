import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

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
        transport: NMTTransport = .tcp,
        heartbeatInterval: Duration = .seconds(30),
        heartbeatMissedLimit: Int = 2,
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
            let channel: Channel
            switch transport {
            case .tcp:
                channel = try await connectTCP(
                    to: address,
                    elg: elg,
                    tls: tls,
                    heartbeatInterval: heartbeatInterval,
                    heartbeatMissedLimit: heartbeatMissedLimit,
                    inboundHandler: inboundHandler
                )
            case .webSocket(let path):
                channel = try await connectWebSocket(
                    to: address,
                    elg: elg,
                    tls: tls,
                    path: path,
                    inboundHandler: inboundHandler
                )
            }
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

    private static func connectTCP(
        to address: SocketAddress,
        elg: MultiThreadedEventLoopGroup,
        tls: (any TLSContext)?,
        heartbeatInterval: Duration,
        heartbeatMissedLimit: Int,
        inboundHandler: NMTClientInboundHandler
    ) async throws -> Channel {
        // Capture only value types to avoid Sendable issues with [any ChannelHandler].
        let idleTime = heartbeatInterval.timeAmount
        return try await ClientBootstrap(group: elg)
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
                            IdleStateHandler(readTimeout: idleTime),
                            HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                            inboundHandler,
                        ]).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                        IdleStateHandler(readTimeout: idleTime),
                        HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                        inboundHandler,
                    ])
                }
            }
            .connect(to: address)
            .get()
    }

    private static func connectWebSocket(
        to address: SocketAddress,
        elg: MultiThreadedEventLoopGroup,
        tls: (any TLSContext)?,
        path: String,
        inboundHandler: NMTClientInboundHandler
    ) async throws -> Channel {
        // Use AsyncStream to bridge the async upgrade completion into structured concurrency.
        var upgradeSignalContinuation: AsyncStream<Void>.Continuation!
        let upgradeSignal = AsyncStream<Void> { upgradeSignalContinuation = $0 }

        // Random 16-byte nonce for Sec-WebSocket-Key (RFC 6455 §4.1).
        let requestKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let channel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                // NIOWebSocketClientUpgrader adds WebSocketFrameDecoder + WebSocketFrameEncoder
                // automatically before calling upgradePipelineHandler.
                let upgrader = NIOWebSocketClientUpgrader(
                    requestKey: requestKey,
                    upgradePipelineHandler: { (ch: Channel, _: HTTPResponseHead) -> EventLoopFuture<Void> in
                        ch.pipeline.addHandlers([
                            NMTWebSocketFrameHandler(isClient: true),
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                            // Note: IdleStateHandler/HeartbeatHandler are not included in the WebSocket
                            // pipeline — same decision as the server side. Heartbeat support for
                            // WebSocket connections is out of scope for this implementation.
                            inboundHandler,
                        ]).map {
                            upgradeSignalContinuation.yield(())
                            upgradeSignalContinuation.finish()
                        }
                    }
                )
                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )
                if let tls {
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let tlsHandler = try await tls.makeClientHandler(serverHostname: nil)
                        try await channel.pipeline.addHandler(tlsHandler).get()
                        try await channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
                }
            }
            .connect(to: address)
            .get()

        // Send the HTTP GET that triggers the WebSocket upgrade handshake.
        let host: String
        switch address {
        case .v4(let addr): host = addr.host
        case .v6(let addr): host = addr.host
        default: host = "localhost"
        }
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
        // Queue head without flushing so both head and end reach the NIO upgrade handler's
        // write() method before any inbound server response can advance its state machine.
        // A separate writeAndFlush(head) would suspend here and yield the event loop;
        // if a fast local server returns 101 during that suspension the state transitions
        // to .upgraderReady, which rejects the subsequent end write with
        // writingToHandlerDuringUpgrade. By queuing head with promise:nil and flushing
        // only when end is sent, both writes are processed in the same event-loop turn.
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        // Safety net: if the server closes the channel without upgrading (e.g. rejects the upgrade),
        // finish the signal so the for-await loop unblocks instead of hanging forever.
        let signalCont = upgradeSignalContinuation!
        channel.closeFuture.whenComplete { _ in
            signalCont.finish()
        }

        // Wait for the server's 101 Switching Protocols and pipeline swap to complete.
        for await _ in upgradeSignal { break }

        guard channel.isActive else {
            throw NMTPError.fail(message: "WebSocket upgrade rejected: server closed connection without upgrading")
        }

        return channel
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
        pushContinuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pendingRequests.failAll(error: error)
        context.close(promise: nil)
    }
}
